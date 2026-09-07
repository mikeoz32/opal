module LF::Microservices
  # Process-local deterministic broker used for conformance tests and
  # development. It intentionally provides no process or restart durability.
  class InMemoryBroker
    @servers = [] of InMemoryServerTransport
    @reply_clients = {} of String => InMemoryClientTransport
    @round_robin = Hash(String, Int32).new(0)
    @lock = Mutex.new

    def initialize(@clock : Proc(Time) = -> { Time.utc })
    end

    def now : Time
      @clock.call
    end

    def register(server : InMemoryServerTransport) : Nil
      @lock.synchronize do
        @servers << server unless @servers.includes?(server)
      end
    end

    def unregister(server : InMemoryServerTransport) : Nil
      @lock.synchronize { @servers.delete(server) }
    end

    def register(client : InMemoryClientTransport) : Nil
      route = client.reply_to.value
      @lock.synchronize do
        if @reply_clients.has_key?(route)
          raise TransportStateError.new("reply route is already registered: #{route}")
        end
        @reply_clients[route] = client
      end
    end

    def unregister(client : InMemoryClientTransport) : Nil
      @lock.synchronize do
        @reply_clients.delete(client.reply_to.value)
      end
    end

    def publish_rpc(target : RPCTarget, publication : Publication) : PublicationReceipt
      unless publication.routing_key == target.routing_key
        raise TransportRejectedError.new("RPC publication routing key does not match target")
      end

      server, had_route = @lock.synchronize do
        candidates = @servers.select(&.accepts?(target))
        {choose_available("rpc:#{target.routing_key}", candidates), !candidates.empty?}
      end
      unless server
        if had_route
          raise TransportCapacityError.new("all RPC destination queues are full")
        end
        if publication.mandatory
          raise TransportUnroutableError.new("no route for RPC target #{target.routing_key}")
        end
        return PublicationReceipt.new(publication.message_id, now, false)
      end

      server.enqueue(delivery(publication))
      PublicationReceipt.new(publication.message_id, now, true)
    end

    def publish_event(identity : EventIdentity, publication : Publication) : PublicationReceipt
      unless publication.routing_key == identity.routing_key
        raise TransportRejectedError.new("event publication routing key does not match identity")
      end

      selected = @lock.synchronize do
        matching = [] of Tuple(InMemoryServerTransport, EventSubscription)
        @servers.each do |server|
          server.matching_subscriptions(identity).each do |subscription|
            matching << {server, subscription}
          end
        end
        select_event_consumers(identity, matching)
      end
      if selected.empty?
        if publication.mandatory
          raise TransportUnroutableError.new("no route for event #{identity.routing_key}")
        end
        return PublicationReceipt.new(publication.message_id, now, false)
      end
      unless selected.all? { |server, _| server.can_accept? }
        raise TransportCapacityError.new("an event destination queue is full")
      end

      selected.each do |server, subscription|
        server.enqueue(delivery(publication, subscription: subscription))
      end
      PublicationReceipt.new(publication.message_id, now, true)
    end

    def publish_reply(publication : Publication) : PublicationReceipt
      client = @lock.synchronize { @reply_clients[publication.routing_key]? }
      unless client
        if publication.mandatory
          raise TransportUnroutableError.new("no reply route #{publication.routing_key}")
        end
        return PublicationReceipt.new(publication.message_id, now, false)
      end
      client.enqueue_reply(delivery(publication))
      PublicationReceipt.new(publication.message_id, now, true)
    end

    private def delivery(
      publication : Publication,
      subscription : EventSubscription? = nil,
    ) : EncodedDelivery
      EncodedDelivery.new(
        publication.message_id,
        publication.routing_key,
        publication.body,
        now,
        headers: publication.headers,
        correlation_id: publication.correlation_id,
        reply_to: publication.reply_to,
        expires_at: publication.expires_at,
        subscription: subscription,
        content_type: publication.content_type,
      )
    end

    private def choose_available(
      key : String,
      candidates : Array(InMemoryServerTransport),
    ) : InMemoryServerTransport?
      available = candidates.select(&.can_accept?)
      return nil if available.empty?
      index = @round_robin[key] % available.size
      @round_robin[key] = (index + 1) % available.size
      available[index]
    end

    private def select_event_consumers(
      identity : EventIdentity,
      matching : Array(Tuple(InMemoryServerTransport, EventSubscription)),
    ) : Array(Tuple(InMemoryServerTransport, EventSubscription))
      selected = [] of Tuple(InMemoryServerTransport, EventSubscription)
      groups = Hash(String, Array(Tuple(InMemoryServerTransport, EventSubscription))).new do |hash, key|
        hash[key] = [] of Tuple(InMemoryServerTransport, EventSubscription)
      end

      matching.each do |server, subscription|
        if subscription.mode.broadcast?
          selected << {server, subscription}
        else
          destination = subscription.destination.try(&.label) || "singleton"
          key = "#{subscription.mode}:#{identity.source.label}:#{identity.routing_key}:" \
                "#{subscription.subscription}:#{destination}"
          groups[key] << {server, subscription}
        end
      end
      groups.each do |key, candidates|
        available = candidates.select { |server, _| server.can_accept? }
        if available.empty?
          raise TransportCapacityError.new("an event consumer group queue is full")
        end
        index = @round_robin[key] % available.size
        @round_robin[key] = (index + 1) % available.size
        selected << available[index]
      end
      selected
    end
  end

  class InMemoryServerTransport < ServerTransport
    getter identity : ServiceIdentity

    @status = TransportStatus::Created
    @rpc_methods = Set(String).new
    @subscriptions = [] of EventSubscription
    @queue = [] of EncodedDelivery
    @inflight = {} of Tuple(UUID, Int32) => EncodedDelivery
    @settled = Set(Tuple(UUID, Int32)).new
    @handler : DeliveryHandler?
    @lock = Mutex.new

    def initialize(
      @broker : InMemoryBroker,
      @identity : ServiceIdentity,
      @max_queue_size : Int32 = 1_024,
    )
      raise TransportCapacityError.new("max_queue_size must be positive") unless max_queue_size > 0
    end

    def status : TransportStatus
      @lock.synchronize { @status }
    end

    def prepare(
      rpc_methods : Enumerable(String),
      subscriptions : Enumerable(EventSubscription),
    ) : Nil
      @lock.synchronize do
        require_status(TransportStatus::Created, "prepare")
        rpc_methods.each do |method|
          Microservices.validate_alias(method, "RPC method")
          @rpc_methods << method
        end
        subscriptions.each do |subscription|
          if destination = subscription.destination
            unless destination == identity
              raise TransportStateError.new(
                "subscription destination #{destination.label} does not match #{identity.label}"
              )
            end
          end
          @subscriptions << subscription
        end
        @status = TransportStatus::Prepared
      end
    end

    def start(handler : DeliveryHandler) : Nil
      @lock.synchronize do
        require_status(TransportStatus::Prepared, "start")
        @handler = handler
        @status = TransportStatus::Running
      end
      @broker.register(self)
    rescue error : Exception
      @lock.synchronize do
        @handler = nil
        @status = TransportStatus::Prepared if @status.running?
      end
      raise error
    end

    def accepts?(target : RPCTarget) : Bool
      @lock.synchronize do
        @status.running? && target.service == identity && @rpc_methods.includes?(target.method)
      end
    end

    def matching_subscriptions(identity : EventIdentity) : Array(EventSubscription)
      @lock.synchronize do
        return [] of EventSubscription unless @status.running?
        @subscriptions.select(&.identity.==(identity))
      end
    end

    def can_accept? : Bool
      @lock.synchronize { @status.running? && @queue.size < @max_queue_size }
    end

    def enqueue(delivery : EncodedDelivery) : Nil
      @lock.synchronize do
        require_status(TransportStatus::Running, "enqueue")
        if @queue.size >= @max_queue_size
          raise TransportCapacityError.new("in-memory server queue is full")
        end
        @queue << delivery
      end
    end

    def pending_count : Int32
      @lock.synchronize { @queue.size }
    end

    def inflight_count : Int32
      @lock.synchronize { @inflight.size }
    end

    def dispatch_one : EncodedDelivery?
      delivery, handler = @lock.synchronize do
        unless @status.in?(TransportStatus::Running, TransportStatus::Quiescing)
          raise TransportStateError.new("dispatch is invalid while transport is #{@status}")
        end
        current = @queue.shift?
        return nil unless current
        selected_handler = @handler || raise TransportStateError.new("server has no delivery handler")
        @inflight[{current.message_id, current.attempt}] = current
        {current, selected_handler}
      end

      outcome = handler.call(delivery)
      settle(delivery, outcome)
      delivery
    end

    def settle(delivery : EncodedDelivery, outcome : SettlementRecommendation) : Nil
      @lock.synchronize do
        key = {delivery.message_id, delivery.attempt}
        unless @inflight.has_key?(key)
          raise DuplicateSettlementError.new(
            "delivery #{delivery.message_id}/#{delivery.attempt} is not unsettled"
          )
        end
        return if outcome.unsettled?

        @inflight.delete(key)
        @settled << key
        if outcome.retry?
          if @queue.size >= @max_queue_size
            raise TransportCapacityError.new("in-memory retry queue is full")
          end
          @queue << EncodedDelivery.new(
            delivery.message_id,
            delivery.routing_key,
            delivery.body,
            @broker.now,
            headers: delivery.headers,
            attempt: delivery.attempt + 1,
            redelivered: true,
            correlation_id: delivery.correlation_id,
            reply_to: delivery.reply_to,
            expires_at: delivery.expires_at,
            subscription: delivery.subscription,
            content_type: delivery.content_type,
          )
        end
      end
    end

    def publish_reply(publication : Publication) : PublicationReceipt
      unless status.in?(TransportStatus::Running, TransportStatus::Quiescing)
        raise TransportStateError.new("publish_reply is invalid while transport is #{status}")
      end
      @broker.publish_reply(publication)
    end

    def stop_intake : Nil
      unregister = @lock.synchronize do
        case @status
        when .running?
          @status = TransportStatus::Quiescing
          true
        when .quiescing?, .closed?
          false
        else
          raise TransportStateError.new("stop_intake is invalid while transport is #{@status}")
        end
      end
      @broker.unregister(self) if unregister
    end

    def drain(deadline : Time::Instant) : Bool
      unless status.in?(TransportStatus::Quiescing, TransportStatus::Closed)
        raise TransportStateError.new("drain requires Quiescing, current status is #{status}")
      end

      loop do
        return true if status.closed?
        if pending_count > 0
          dispatch_one
        elsif inflight_count == 0
          return true
        end
        return false if Time.instant >= deadline
        Fiber.yield
      end
    end

    def close : Nil
      @broker.unregister(self)
      @lock.synchronize do
        return if @status.closed?
        @queue.clear
        @inflight.clear
        @handler = nil
        @status = TransportStatus::Closed
      end
    end

    private def require_status(expected : TransportStatus, operation : String) : Nil
      unless @status == expected
        raise TransportStateError.new(
          "#{operation} requires #{expected}, current status is #{@status}"
        )
      end
    end
  end

  class InMemoryClientTransport < ClientTransport
    @status = TransportStatus::Created
    @generation = 0_i64
    @receive_replies = true
    @pending = Set(UUID).new
    @replies = [] of EncodedDelivery
    @lock = Mutex.new

    getter reply_to : ReplyRoute

    def initialize(
      @broker : InMemoryBroker,
      @topology : TopologyConfig = TopologyConfig.new,
      @max_pending : Int32 = 1_024,
      @max_replies : Int32 = 1_024,
    )
      raise TransportCapacityError.new("max_pending must be positive") unless max_pending > 0
      raise TransportCapacityError.new("max_replies must be positive") unless max_replies > 0
      @reply_to = topology.reply_route
    end

    def status : TransportStatus
      @lock.synchronize { @status }
    end

    def generation : Int64
      @lock.synchronize { @generation }
    end

    def start(receive_replies : Bool = true) : Nil
      @lock.synchronize do
        unless @status.created?
          raise TransportStateError.new("start requires Created, current status is #{@status}")
        end
        @receive_replies = receive_replies
        @generation += 1
        @status = TransportStatus::Running
      end
      @broker.register(self) if receive_replies
    rescue error : Exception
      @lock.synchronize do
        @generation -= 1
        @status = TransportStatus::Created
      end
      raise error
    end

    def publish_rpc(target : RPCTarget, publication : Publication) : PublicationReceipt
      correlation_id = publication.correlation_id || raise TransportRejectedError.new(
        "RPC publication requires correlation_id"
      )
      unless publication.reply_to == reply_to
        raise TransportRejectedError.new("RPC publication reply_to does not match client route")
      end
      @lock.synchronize do
        require_running("publish_rpc")
        unless @receive_replies
          raise TransportStateError.new("publisher-only client cannot publish RPC requests")
        end
        if @pending.size >= @max_pending
          raise TransportCapacityError.new("in-memory pending RPC capacity is full")
        end
        if @pending.includes?(correlation_id)
          raise TransportCorrelationError.new("correlation_id is already pending")
        end
        @pending << correlation_id
      end

      receipt = @broker.publish_rpc(target, publication)
      cancel_pending(correlation_id) unless receipt.routed
      receipt
    rescue error : Exception
      cancel_pending(correlation_id) if correlation_id
      raise error
    end

    def publish_event(identity : EventIdentity, publication : Publication) : PublicationReceipt
      @lock.synchronize { require_running("publish_event") }
      @broker.publish_event(identity, publication)
    end

    def enqueue_reply(delivery : EncodedDelivery) : Nil
      @lock.synchronize do
        require_running("enqueue_reply")
        if @replies.size >= @max_replies
          raise TransportCapacityError.new("in-memory reply queue is full")
        end
        @replies << delivery
      end
    end

    def next_reply? : EncodedDelivery | ReplyProtocolFailure | Nil
      delivery = @lock.synchronize do
        require_running("next_reply?")
        @replies.shift?
      end
      return nil unless delivery
      correlation_id = delivery.correlation_id
      unless correlation_id
        raise TransportCorrelationError.new("reply delivery has no correlation_id")
      end
      known = @lock.synchronize { @pending.delete(correlation_id) }
      unless known
        return ReplyProtocolFailure.new(correlation_id, "reply correlation_id is not pending")
      end
      delivery
    end

    def cancel_pending(correlation_id : UUID) : Nil
      @lock.synchronize { @pending.delete(correlation_id) }
    end

    def pending_count : Int32
      @lock.synchronize { @pending.size }
    end

    # Replaces the ephemeral reply route and returns correlations whose accepted
    # outcomes can no longer be observed. A typed RPC client maps these IDs to
    # outcome-unknown failures; the transport never replays them.
    def reconnect : Array(UUID)
      receive_replies = @lock.synchronize do
        require_running("reconnect")
        @status = TransportStatus::Prepared
        @receive_replies
      end
      @broker.unregister(self) if receive_replies
      canceled = @lock.synchronize do
        values = @pending.to_a
        @pending.clear
        @replies.clear
        @reply_to = @topology.reply_route
        @generation += 1
        values
      end
      @broker.register(self) if receive_replies
      @lock.synchronize { @status = TransportStatus::Running }
      canceled
    end

    def close : Nil
      @broker.unregister(self)
      @lock.synchronize do
        return if @status.closed?
        @pending.clear
        @replies.clear
        @status = TransportStatus::Closed
      end
    end

    private def require_running(operation : String) : Nil
      unless @status.running?
        raise TransportStateError.new(
          "#{operation} requires Running, current status is #{@status}"
        )
      end
    end
  end
end
