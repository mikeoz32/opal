module LF::Microservices
  enum TransportStatus
    Created
    Prepared
    Running
    Quiescing
    Closed
  end

  enum SettlementRecommendation
    Ack
    Retry
    Reject
    Unsettled
  end

  enum EventDispatchMode
    ServicePool
    Singleton
    Broadcast
  end

  struct EventSubscription
    getter identity : EventIdentity
    getter mode : EventDispatchMode
    getter subscription : String
    getter destination : ServiceIdentity?
    getter instance_id : String?
    getter reliable : Bool

    def initialize(
      @identity : EventIdentity,
      @mode : EventDispatchMode,
      @subscription : String,
      @destination : ServiceIdentity? = nil,
      instance_id : String? = nil,
      reliable : Bool? = nil,
    )
      Microservices.validate_alias(subscription, "subscription")
      @reliable = reliable.nil? ? mode.in?(EventDispatchMode::ServicePool, EventDispatchMode::Singleton) : reliable
      @instance_id = instance_id
      Microservices.validate_alias(instance_id, "instance_id") if instance_id

      if mode.in?(EventDispatchMode::ServicePool, EventDispatchMode::Singleton) && !@reliable
        raise TransportStateError.new("#{mode.to_s.underscore} subscriptions must be reliable")
      end
      if mode.service_pool? && destination.nil?
        raise TransportStateError.new("service_pool subscriptions require a destination")
      end
      if mode.broadcast?
        raise TransportStateError.new("broadcast subscriptions require a destination") if destination.nil?
        if @reliable && instance_id.nil?
          raise TransportStateError.new("reliable broadcast subscriptions require an instance_id")
        end
        @instance_id ||= "instance-#{UUID.random.hexstring}"
      end
    end
  end

  struct Publication
    getter message_id : UUID
    getter routing_key : String
    @body : Bytes
    @headers : Hash(String, JSON::Any)
    getter mandatory : Bool
    getter correlation_id : UUID?
    getter reply_to : ReplyRoute?
    getter expires_at : Time?
    getter content_type : String?

    def initialize(
      @message_id : UUID,
      @routing_key : String,
      body : Bytes,
      headers : Hash(String, JSON::Any) = {} of String => JSON::Any,
      @mandatory : Bool = false,
      @correlation_id : UUID? = nil,
      @reply_to : ReplyRoute? = nil,
      @expires_at : Time? = nil,
      @content_type : String? = nil,
      limits : MessageLimits = MessageLimits.new,
    )
      validate_route(routing_key)
      WireValue.validate_utc(expires_at, "expires_at") if expires_at
      raise WireError.new("content_type must not be empty") if content_type.try(&.empty?)
      @body = body.dup
      @headers = WireValue.deep_copy(headers)
      WireValue.validate_headers(@headers, limits)
      if body.size > limits.max_envelope_bytes
        raise WireLimitError.new("publication body exceeds the configured byte limit")
      end
    end

    def body : Bytes
      @body.dup
    end

    def headers : Hash(String, JSON::Any)
      WireValue.deep_copy(@headers)
    end

    private def validate_route(value : String) : Nil
      raise TransportStateError.new("routing_key must be a non-empty string") if value.empty?
      if value.bytesize > MAX_AMQP_NAME_BYTES
        raise TransportStateError.new("routing_key exceeds RabbitMQ's 255-byte limit")
      end
    end
  end

  struct EncodedDelivery
    getter message_id : UUID
    getter routing_key : String
    @body : Bytes
    @headers : Hash(String, JSON::Any)
    getter received_at : Time
    getter attempt : Int32
    getter redelivered : Bool
    getter correlation_id : UUID?
    getter reply_to : ReplyRoute?
    getter expires_at : Time?
    getter subscription : EventSubscription?
    getter content_type : String?

    def initialize(
      @message_id : UUID,
      @routing_key : String,
      body : Bytes,
      @received_at : Time,
      headers : Hash(String, JSON::Any) = {} of String => JSON::Any,
      attempt : Int = 1,
      @redelivered : Bool = false,
      @correlation_id : UUID? = nil,
      @reply_to : ReplyRoute? = nil,
      @expires_at : Time? = nil,
      @subscription : EventSubscription? = nil,
      @content_type : String? = nil,
      limits : MessageLimits = MessageLimits.new,
    )
      raise TransportStateError.new("routing_key must be a non-empty string") if routing_key.empty?
      if routing_key.bytesize > MAX_AMQP_NAME_BYTES
        raise TransportStateError.new("routing_key exceeds RabbitMQ's 255-byte limit")
      end
      unless attempt > 0 && attempt <= Int32::MAX
        raise TransportStateError.new("attempt must be a positive 32-bit integer")
      end
      @attempt = attempt.to_i32
      WireValue.validate_utc(received_at, "received_at")
      WireValue.validate_utc(expires_at, "expires_at") if expires_at
      raise WireError.new("content_type must not be empty") if content_type.try(&.empty?)
      @body = body.dup
      @headers = WireValue.deep_copy(headers)
      WireValue.validate_headers(@headers, limits)
      if body.size > limits.max_envelope_bytes
        raise WireLimitError.new("delivery body exceeds the configured byte limit")
      end
    end

    def body : Bytes
      @body.dup
    end

    def headers : Hash(String, JSON::Any)
      WireValue.deep_copy(@headers)
    end

    def expired?(at : Time = Time.utc) : Bool
      expires_at.try { |expires| expires <= at } || false
    end
  end

  struct PublicationReceipt
    getter message_id : UUID
    getter accepted_at : Time
    getter routed : Bool

    def initialize(@message_id : UUID, @accepted_at : Time, @routed : Bool)
      WireValue.validate_utc(accepted_at, "accepted_at")
    end
  end

  struct ReplyProtocolFailure
    getter correlation_id : UUID
    getter reason : String

    def initialize(@correlation_id : UUID, @reason : String)
      raise TransportCorrelationError.new("reason must be a non-empty string") if reason.empty?
    end
  end

  struct TransportStatusEvent
    getter status : TransportStatus
    getter changed_at : Time
    getter detail : String
    getter generation : Int64

    def initialize(
      @status : TransportStatus,
      @changed_at : Time,
      @detail : String = "",
      @generation : Int64 = 0_i64,
    )
      WireValue.validate_utc(changed_at, "changed_at")
      raise TransportStateError.new("generation must be non-negative") if generation < 0
    end
  end

  alias DeliveryHandler = Proc(EncodedDelivery, SettlementRecommendation)

  abstract class ServerTransport
    abstract def status : TransportStatus
    abstract def prepare(rpc_methods : Enumerable(String), subscriptions : Enumerable(EventSubscription)) : Nil
    abstract def start(handler : DeliveryHandler) : Nil
    abstract def settle(delivery : EncodedDelivery, outcome : SettlementRecommendation) : Nil
    abstract def publish_reply(publication : Publication) : PublicationReceipt
    abstract def stop_intake : Nil
    # Drains work accepted before `stop_intake`. Returns false when the
    # transport cannot finish before the monotonic deadline.
    abstract def drain(deadline : Time::Instant) : Bool
    abstract def close : Nil
  end

  abstract class ClientTransport
    abstract def status : TransportStatus
    abstract def generation : Int64
    abstract def reply_to : ReplyRoute
    abstract def start(receive_replies : Bool = true) : Nil
    abstract def publish_rpc(target : RPCTarget, publication : Publication) : PublicationReceipt
    abstract def publish_event(identity : EventIdentity, publication : Publication) : PublicationReceipt
    abstract def next_reply : EncodedDelivery | ReplyProtocolFailure
    abstract def cancel_pending(correlation_id : UUID) : Nil
    # Replaces transport-owned ephemeral reply state and returns accepted RPC
    # correlations whose outcomes can no longer be observed. Implementations
    # must never replay those requests automatically.
    abstract def reconnect : Array(UUID)
    abstract def close : Nil
  end
end
