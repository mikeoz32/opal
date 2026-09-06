module LF::Microservices::RabbitMQ
  # Deterministically derives RabbitMQ event, retry, and dead-letter queue names
  # from a protocol topology profile.
  class Topology
    getter config : TopologyConfig

    def initialize(@config : TopologyConfig)
    end

    def retry_exchange : String
      config.retry_exchange_prefix
    end

    def dead_letter_exchange : String
      config.dead_letter_exchange
    end

    def event_queue(subscription : EventSubscription) : String
      base = config.event_queue_base(subscription.identity)
      suffix = case subscription.mode
               when .service_pool?
                 destination = subscription.destination.not_nil!
                 "service_pool.#{destination.label}.#{subscription.subscription}"
               when .singleton?
                 "singleton.#{subscription.subscription}"
               when .broadcast?
                 destination = subscription.destination.not_nil!
                 "broadcast.#{destination.label}.#{subscription.subscription}.#{subscription.instance_id.not_nil!}"
               end
      queue_name("#{base}.#{suffix}", "event queue")
    end

    def retry_queue(queue : String, discriminator : String? = nil) : String
      suffix = discriminator ? ".#{discriminator}" : ""
      queue_name("#{queue}.retry#{suffix}", "retry queue")
    end

    def dead_letter_queue(queue : String) : String
      queue_name("#{queue}.dead", "dead-letter queue")
    end

    private def queue_name(value : String, field : String) : String
      if value.bytesize > MAX_AMQP_NAME_BYTES
        raise ConfigurationError.new("RabbitMQ #{field} exceeds the 255-byte name limit")
      end
      value
    end
  end

  private struct RetryRoute
    getter routing_key : String

    def initialize(@routing_key : String)
    end
  end

  private struct InflightDelivery
    getter broker : BrokerDelivery
    getter retry_route : RetryRoute?

    def initialize(@broker : BrokerDelivery, @retry_route : RetryRoute?)
    end
  end

  # AMQP 0-9-1 server adapter with durable bounded work queues, manual
  # settlement, publisher-confirmed replies, finite retries, and dead lettering.
  class ServerTransport < LF::Microservices::ServerTransport
    getter identity : ServiceIdentity
    getter settings : Settings
    getter profile : ProtocolProfile

    @topology : Topology
    @session_factory : SessionFactory
    @session : Session?
    @status = TransportStatus::Created
    @rpc_methods = [] of String
    @subscriptions = [] of EventSubscription
    @consumer_tags = [] of String
    @inflight = {} of Tuple(UUID, Int32) => InflightDelivery
    @handler : DeliveryHandler?
    @lock = Mutex.new

    def initialize(
      @identity : ServiceIdentity,
      @settings : Settings,
      @profile : ProtocolProfile = ProtocolProfile.new,
      session_factory : SessionFactory? = nil,
      @clock : Proc(Time) = -> { Microservices.utc_now },
    )
      @topology = Topology.new(profile.topology)
      @session_factory = session_factory || SessionFactory.new do
        CloudAMQPSession.new(settings.url, @clock).as(Session)
      end
    end

    def status : TransportStatus
      @lock.synchronize { @status }
    end

    def pending_count : Int32
      0
    end

    def inflight_count : Int32
      @lock.synchronize { @inflight.size }
    end

    def prepare(
      rpc_methods : Enumerable(String),
      subscriptions : Enumerable(EventSubscription),
    ) : Nil
      @lock.synchronize do
        require_status(TransportStatus::Created, "prepare")
        rpc_methods.each do |method|
          Microservices.validate_alias(method, "RPC method")
          @rpc_methods << method unless @rpc_methods.includes?(method)
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
      end
      created_session = @session_factory.call
      created_session.on_disconnect do |_error|
        # Status remains Running until quiesce so ApplicationRuntime still
        # drains any handler fibers that already own message scopes.
      end
      declare_topology(created_session)
      @lock.synchronize do
        @session = created_session
        @status = TransportStatus::Running
      end
      start_consumers(created_session)
    rescue error : Exception
      created_session.try(&.close)
      @lock.synchronize do
        @session = nil
        @handler = nil
        @consumer_tags.clear
        @status = TransportStatus::Prepared unless @status.closed?
      end
      raise TransportUnavailableError.new("RabbitMQ server transport failed to start", error)
    end

    def settle(delivery : EncodedDelivery, outcome : SettlementRecommendation) : Nil
      return if outcome.unsettled?

      key = {delivery.message_id, delivery.attempt}
      inflight = @lock.synchronize do
        @inflight.delete(key) || raise DuplicateSettlementError.new(
          "delivery #{delivery.message_id}/#{delivery.attempt} is not unsettled"
        )
      end

      begin
        case outcome
        when .ack?
          current_session.ack(inflight.broker.token)
        when .reject?
          current_session.reject(inflight.broker.token, requeue: false)
        when .retry?
          retry_delivery(delivery, inflight)
        when .unsettled?
        end
      rescue error : Exception
        @lock.synchronize { @inflight[key] = inflight }
        raise error
      end
    end

    def publish_reply(publication : Publication) : PublicationReceipt
      unless status.in?(TransportStatus::Running, TransportStatus::Quiescing)
        raise TransportStateError.new("publish_reply is invalid while transport is #{status}")
      end
      publish_confirmed("", publication, persistent: false)
    end

    def stop_intake : Nil
      tags = @lock.synchronize do
        case @status
        when .running?
          @status = TransportStatus::Quiescing
          @consumer_tags.dup
        when .quiescing?, .closed?
          return
        else
          raise TransportStateError.new("stop_intake is invalid while transport is #{@status}")
        end
      end
      tags.each { |tag| current_session.cancel(tag) }
    rescue error : Exception
      raise TransportUnavailableError.new("RabbitMQ consumers could not stop intake", error)
    end

    def drain(deadline : Time::Instant) : Bool
      unless status.in?(TransportStatus::Quiescing, TransportStatus::Closed)
        raise TransportStateError.new("drain requires Quiescing, current status is #{status}")
      end
      loop do
        return true if inflight_count == 0
        return false if Time.instant >= deadline
        sleep 1.millisecond
      end
    end

    def close : Nil
      active_session = @lock.synchronize do
        return if @status.closed?
        @status = TransportStatus::Closed
        @handler = nil
        @consumer_tags.clear
        @inflight.clear
        value = @session
        @session = nil
        value
      end
      active_session.try(&.close)
    rescue error : Exception
      raise TransportUnavailableError.new("RabbitMQ server transport failed to close", error)
    end

    private def declare_topology(session : Session) : Nil
      topology = profile.topology
      session.declare_exchange(topology.rpc_exchange, "topic", durable: true)
      session.declare_exchange(@topology.retry_exchange, "topic", durable: true)
      session.declare_exchange(@topology.dead_letter_exchange, "topic", durable: true)

      unless @rpc_methods.empty?
        rpc_queue = topology.rpc_queue(identity)
        declare_primary_queue(session, rpc_queue, topology.rpc_exchange, topology.rpc_binding(identity))
        @rpc_methods.each do |method|
          target = RPCTarget.new(identity, method, 1)
          declare_retry_queue(
            session,
            rpc_queue,
            method,
            topology.rpc_exchange,
            target.routing_key,
          )
        end
      end

      @subscriptions.each do |subscription|
        event_exchange = topology.event_exchange(subscription.identity.source)
        session.declare_exchange(event_exchange, "topic", durable: true)
        queue = @topology.event_queue(subscription)
        if subscription.reliable
          declare_primary_queue(session, queue, event_exchange, subscription.identity.routing_key)
          declare_retry_queue(
            session,
            queue,
            nil,
            event_exchange,
            subscription.identity.routing_key,
          )
        else
          session.declare_queue(
            queue,
            QueueOptions.new(durable: false, exclusive: true, auto_delete: true, max_length: settings.max_queue_length),
          )
          session.bind_queue(queue, event_exchange, subscription.identity.routing_key)
        end
      end
    end

    private def declare_primary_queue(
      session : Session,
      queue : String,
      exchange : String,
      binding : String,
    ) : Nil
      session.declare_queue(
        queue,
        QueueOptions.new(
          durable: true,
          dead_letter_exchange: @topology.dead_letter_exchange,
          max_length: settings.max_queue_length,
        ),
      )
      session.bind_queue(queue, exchange, binding)
      dead_queue = @topology.dead_letter_queue(queue)
      session.declare_queue(
        dead_queue,
        QueueOptions.new(durable: true, max_length: settings.max_queue_length),
      )
      session.bind_queue(dead_queue, @topology.dead_letter_exchange, binding)
    end

    private def declare_retry_queue(
      session : Session,
      primary_queue : String,
      discriminator : String?,
      source_exchange : String,
      source_routing_key : String,
    ) : RetryRoute
      retry_queue = @topology.retry_queue(primary_queue, discriminator)
      session.declare_queue(
        retry_queue,
        QueueOptions.new(
          durable: true,
          dead_letter_exchange: source_exchange,
          dead_letter_routing_key: source_routing_key,
          message_ttl: settings.retry_delay,
          max_length: settings.max_queue_length,
        ),
      )
      session.bind_queue(retry_queue, @topology.retry_exchange, retry_queue)
      RetryRoute.new(retry_queue)
    end

    private def start_consumers(session : Session) : Nil
      unless @rpc_methods.empty?
        queue = profile.topology.rpc_queue(identity)
        tag = session.consume(
          queue,
          "opal-rpc-#{Random::Secure.hex(8)}",
          settings.prefetch,
          settings.work_pool,
        ) do |broker_delivery|
          method = broker_delivery.routing_key.split('.').last
          retry_route = RetryRoute.new(@topology.retry_queue(queue, method))
          dispatch_broker(broker_delivery, nil, retry_route)
        end
        @lock.synchronize { @consumer_tags << tag }
      end

      @subscriptions.each do |subscription|
        queue = @topology.event_queue(subscription)
        retry_route = subscription.reliable ? RetryRoute.new(@topology.retry_queue(queue)) : nil
        tag = session.consume(
          queue,
          "opal-event-#{Random::Secure.hex(8)}",
          settings.prefetch,
          settings.work_pool,
        ) do |broker_delivery|
          dispatch_broker(broker_delivery, subscription, retry_route)
        end
        @lock.synchronize { @consumer_tags << tag }
      end
    end

    private def dispatch_broker(
      broker : BrokerDelivery,
      subscription : EventSubscription?,
      retry_route : RetryRoute?,
    ) : Nil
      delivery = encoded_delivery(broker, subscription)
      key = {delivery.message_id, delivery.attempt}
      @lock.synchronize do
        if @inflight.has_key?(key)
          raise TransportCorrelationError.new(
            "RabbitMQ delivery #{delivery.message_id}/#{delivery.attempt} is already inflight"
          )
        end
        @inflight[key] = InflightDelivery.new(broker, retry_route)
      end
      outcome = current_handler.call(delivery)
      settle(delivery, outcome)
    rescue error : Exception
      if delivery
        @lock.synchronize { @inflight.delete({delivery.message_id, delivery.attempt}) }
      end
      current_session.reject(broker.token, requeue: false)
    end

    private def encoded_delivery(
      broker : BrokerDelivery,
      subscription : EventSubscription?,
    ) : EncodedDelivery
      message_id = parse_uuid(broker.message_id, "message_id")
      correlation_id = parse_optional_uuid(broker.correlation_id, "correlation_id")
      reply_to = broker.reply_to.try { |value| ReplyRoute.new(value) }
      headers = broker.headers
      attempt = headers.delete(ATTEMPT_HEADER).try(&.as_i64) || 1_i64
      unless attempt > 0 && attempt <= Int32::MAX
        raise WireDecodingError.new("RabbitMQ #{ATTEMPT_HEADER} must be a positive 32-bit integer")
      end
      received_at = @clock.call
      expires_at = broker.expiration_ms.try { |milliseconds| received_at + milliseconds.milliseconds }
      EncodedDelivery.new(
        message_id,
        broker.routing_key,
        broker.body,
        received_at,
        headers: headers,
        attempt: attempt.to_i32,
        redelivered: broker.redelivered,
        correlation_id: correlation_id,
        reply_to: reply_to,
        expires_at: expires_at,
        subscription: subscription,
        content_type: broker.content_type,
        limits: profile.limits,
      )
    end

    private def retry_delivery(delivery : EncodedDelivery, inflight : InflightDelivery) : Nil
      retry_route = inflight.retry_route
      unless retry_route && delivery.attempt < settings.max_attempts
        current_session.reject(inflight.broker.token, requeue: false)
        return
      end

      headers = delivery.headers
      headers[ATTEMPT_HEADER] = JSON::Any.new((delivery.attempt + 1).to_i64)
      publication = Publication.new(
        delivery.message_id,
        retry_route.routing_key,
        delivery.body,
        headers: headers,
        mandatory: true,
        correlation_id: delivery.correlation_id,
        reply_to: delivery.reply_to,
        expires_at: delivery.expires_at,
        content_type: delivery.content_type,
        limits: profile.limits,
      )
      publish_confirmed(@topology.retry_exchange, publication, persistent: true)
      current_session.ack(inflight.broker.token)
    end

    private def publish_confirmed(
      exchange : String,
      publication : Publication,
      persistent : Bool,
    ) : PublicationReceipt
      result = current_session.publish(exchange, publication, persistent)
      unless result.confirmed
        raise TransportRejectedError.new("RabbitMQ negatively acknowledged publication")
      end
      if publication.mandatory && !result.routed
        raise TransportUnroutableError.new(
          "RabbitMQ returned mandatory publication for #{publication.routing_key}"
        )
      end
      PublicationReceipt.new(publication.message_id, @clock.call, result.routed)
    rescue error : TransportRejectedError | TransportUnroutableError
      raise error
    rescue error : Exception
      raise TransportIndeterminateError.new(
        "RabbitMQ publication outcome is unknown",
        error,
      )
    end

    private def current_session : Session
      @lock.synchronize do
        @session || raise TransportUnavailableError.new("RabbitMQ server session is unavailable")
      end
    end

    private def current_handler : DeliveryHandler
      @lock.synchronize do
        @handler || raise TransportStateError.new("RabbitMQ server has no delivery handler")
      end
    end

    private def parse_uuid(value : String?, field : String) : UUID
      text = value || raise WireDecodingError.new("RabbitMQ #{field} is required")
      parsed = UUID.new(text)
      unless parsed.to_s == text
        raise WireDecodingError.new("RabbitMQ #{field} must use canonical UUID text")
      end
      parsed
    rescue ArgumentError
      raise WireDecodingError.new("RabbitMQ #{field} must be a UUID")
    end

    private def parse_optional_uuid(value : String?, field : String) : UUID?
      value ? parse_uuid(value, field) : nil
    end

    private def require_status(expected : TransportStatus, operation : String) : Nil
      unless @status == expected
        raise TransportStateError.new(
          "#{operation} requires #{expected}, current status is #{@status}"
        )
      end
    end
  end

  # AMQP 0-9-1 client adapter with confirmed mandatory publications and one
  # bounded exclusive reply queue per connection generation.
  #
  # Reconnect replaces the reply queue and returns every accepted correlation
  # whose outcome became unknowable. Requests are never replayed automatically.
  class ClientTransport < LF::Microservices::ClientTransport
    getter settings : Settings
    getter profile : ProtocolProfile
    getter reply_to : ReplyRoute

    @session_factory : SessionFactory
    @session : Session?
    @status = TransportStatus::Created
    @generation = 0_i64
    @pending = Set(UUID).new
    @replies = [] of EncodedDelivery
    @receive_replies = true
    @consumer_tag : String?
    @lock = Mutex.new

    def initialize(
      @settings : Settings,
      @profile : ProtocolProfile = ProtocolProfile.new,
      session_factory : SessionFactory? = nil,
      @max_pending : Int32 = 1_024,
      @max_replies : Int32 = 1_024,
      @clock : Proc(Time) = -> { Microservices.utc_now },
    )
      raise TransportCapacityError.new("max_pending must be positive") unless max_pending > 0
      raise TransportCapacityError.new("max_replies must be positive") unless max_replies > 0
      @reply_to = profile.topology.reply_route
      @session_factory = session_factory || SessionFactory.new do
        CloudAMQPSession.new(settings.url, @clock).as(Session)
      end
    end

    def status : TransportStatus
      @lock.synchronize { @status }
    end

    def generation : Int64
      @lock.synchronize { @generation }
    end

    def pending_count : Int32
      @lock.synchronize { @pending.size }
    end

    def start(receive_replies : Bool = true) : Nil
      @lock.synchronize do
        unless @status.created?
          raise TransportStateError.new("start requires Created, current status is #{@status}")
        end
        @receive_replies = receive_replies
      end
      connect
    end

    def publish_rpc(target : RPCTarget, publication : Publication) : PublicationReceipt
      correlation_id = publication.correlation_id || raise TransportRejectedError.new(
        "RPC publication requires correlation_id"
      )
      unless publication.reply_to == reply_to
        raise TransportRejectedError.new("RPC publication reply_to does not match client route")
      end
      unless publication.routing_key == target.routing_key
        raise TransportRejectedError.new("RPC publication routing key does not match target")
      end
      @lock.synchronize do
        require_running("publish_rpc")
        unless @receive_replies
          raise TransportStateError.new("publisher-only client cannot publish RPC requests")
        end
        if @pending.size >= @max_pending
          raise TransportCapacityError.new("RabbitMQ pending RPC capacity is full")
        end
        if @pending.includes?(correlation_id)
          raise TransportCorrelationError.new("correlation_id is already pending")
        end
        @pending << correlation_id
      end

      receipt = publish_confirmed(profile.topology.rpc_exchange, publication, persistent: true)
      cancel_pending(correlation_id) unless receipt.routed
      receipt
    rescue error : Exception
      cancel_pending(correlation_id) if correlation_id
      raise error
    end

    def publish_event(identity : EventIdentity, publication : Publication) : PublicationReceipt
      @lock.synchronize { require_running("publish_event") }
      unless publication.routing_key == identity.routing_key
        raise TransportRejectedError.new("event publication routing key does not match identity")
      end
      publish_confirmed(
        profile.topology.event_exchange(identity.source),
        publication,
        persistent: true,
      )
    end

    def next_reply? : EncodedDelivery | ReplyProtocolFailure | Nil
      delivery = @lock.synchronize do
        require_running("next_reply?")
        @replies.shift?
      end
      unless delivery
        if current_session.closed?
          raise TransportUnavailableError.new("RabbitMQ reply session is disconnected")
        end
        return nil
      end

      correlation_id = delivery.correlation_id || raise TransportCorrelationError.new(
        "reply delivery has no correlation_id"
      )
      known = @lock.synchronize { @pending.delete(correlation_id) }
      unless known
        return ReplyProtocolFailure.new(correlation_id, "reply correlation_id is not pending")
      end
      delivery
    end

    def cancel_pending(correlation_id : UUID) : Nil
      @lock.synchronize { @pending.delete(correlation_id) }
    end

    def reconnect : Array(UUID)
      old_session, canceled = @lock.synchronize do
        require_running("reconnect")
        @status = TransportStatus::Prepared
        values = @pending.to_a
        @pending.clear
        @replies.clear
        current = @session
        @session = nil
        @consumer_tag = nil
        {current, values}
      end
      old_session.try(&.close)
      @reply_to = profile.topology.reply_route
      connect
      canceled
    rescue error : Exception
      raise error if error.is_a?(TransportError)
      raise TransportUnavailableError.new("RabbitMQ client reconnect failed", error)
    end

    def close : Nil
      active_session = @lock.synchronize do
        return if @status.closed?
        @status = TransportStatus::Closed
        @pending.clear
        @replies.clear
        @consumer_tag = nil
        value = @session
        @session = nil
        value
      end
      active_session.try(&.close)
    rescue error : Exception
      raise TransportUnavailableError.new("RabbitMQ client transport failed to close", error)
    end

    private def connect : Nil
      created_session = @session_factory.call
      created_session.on_disconnect do |_error|
        # Calls already accepted by this generation are resolved by explicit
        # reconnect as outcome-unknown; no implicit replay occurs here.
      end
      consumer_tag = setup_reply_consumer(created_session) if @receive_replies
      @lock.synchronize do
        @session = created_session
        @consumer_tag = consumer_tag
        @generation += 1
        @status = TransportStatus::Running
      end
    rescue error : Exception
      created_session.try(&.close)
      @lock.synchronize do
        @session = nil
        @consumer_tag = nil
        @status = TransportStatus::Prepared unless @status.closed?
      end
      raise TransportUnavailableError.new("RabbitMQ client transport failed to connect", error)
    end

    private def setup_reply_consumer(session : Session) : String
      session.declare_queue(
        reply_to.value,
        QueueOptions.new(
          durable: false,
          exclusive: true,
          auto_delete: true,
          max_length: @max_replies,
        ),
      )
      session.consume(
        reply_to.value,
        "opal-reply-#{Random::Secure.hex(8)}",
        settings.prefetch,
        1,
      ) do |broker|
        receive_reply(session, broker)
      end
    end

    private def receive_reply(session : Session, broker : BrokerDelivery) : Nil
      delivery = encoded_reply(broker)
      accepted = @lock.synchronize do
        next false unless @status.running?
        next false if @replies.size >= @max_replies
        @replies << delivery
        true
      end
      if accepted
        session.ack(broker.token)
      else
        session.reject(broker.token, requeue: false)
      end
    rescue error : Exception
      session.reject(broker.token, requeue: false)
    end

    private def encoded_reply(broker : BrokerDelivery) : EncodedDelivery
      message_id = parse_uuid(broker.message_id, "message_id")
      correlation_id = parse_optional_uuid(broker.correlation_id, "correlation_id")
      EncodedDelivery.new(
        message_id,
        broker.routing_key,
        broker.body,
        @clock.call,
        headers: broker.headers,
        redelivered: broker.redelivered,
        correlation_id: correlation_id,
        content_type: broker.content_type,
        limits: profile.limits,
      )
    end

    private def publish_confirmed(
      exchange : String,
      publication : Publication,
      persistent : Bool,
    ) : PublicationReceipt
      result = current_session.publish(exchange, publication, persistent)
      unless result.confirmed
        raise TransportRejectedError.new("RabbitMQ negatively acknowledged publication")
      end
      if publication.mandatory && !result.routed
        raise TransportUnroutableError.new(
          "RabbitMQ returned mandatory publication for #{publication.routing_key}"
        )
      end
      PublicationReceipt.new(publication.message_id, @clock.call, result.routed)
    rescue error : TransportRejectedError | TransportUnroutableError
      raise error
    rescue error : Exception
      raise TransportIndeterminateError.new(
        "RabbitMQ publication outcome is unknown",
        error,
      )
    end

    private def current_session : Session
      @lock.synchronize do
        @session || raise TransportUnavailableError.new("RabbitMQ client session is unavailable")
      end
    end

    private def parse_uuid(value : String?, field : String) : UUID
      text = value || raise WireDecodingError.new("RabbitMQ #{field} is required")
      parsed = UUID.new(text)
      unless parsed.to_s == text
        raise WireDecodingError.new("RabbitMQ #{field} must use canonical UUID text")
      end
      parsed
    rescue ArgumentError
      raise WireDecodingError.new("RabbitMQ #{field} must be a UUID")
    end

    private def parse_optional_uuid(value : String?, field : String) : UUID?
      value ? parse_uuid(value, field) : nil
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
