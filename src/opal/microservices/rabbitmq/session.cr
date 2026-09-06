module LF::Microservices::RabbitMQ
  # Broker-only delivery-attempt header. It is never exposed as an application
  # envelope header.
  ATTEMPT_HEADER = "opal-attempt"

  # Validated RabbitMQ connection, flow-control, and retry settings.
  #
  # `url` may use `amqp://` or `amqps://`; URI validation and TLS negotiation
  # are delegated to `amqp-client`. All capacity and timing controls are finite.
  struct Settings
    getter url : String
    getter prefetch : UInt16
    getter work_pool : Int32
    getter max_attempts : Int32
    getter max_queue_length : Int32
    getter retry_delay : Time::Span

    def initialize(
      @url : String,
      prefetch : Int = 32,
      work_pool : Int = 1,
      max_attempts : Int = 3,
      max_queue_length : Int = 10_000,
      @retry_delay : Time::Span = 1.second,
    )
      raise ConfigurationError.new("RabbitMQ URL must not be empty") if url.empty?
      unless prefetch > 0 && prefetch <= UInt16::MAX
        raise ConfigurationError.new("RabbitMQ prefetch must be between 1 and #{UInt16::MAX}")
      end
      unless work_pool > 0 && work_pool <= 1_024
        raise ConfigurationError.new("RabbitMQ work_pool must be between 1 and 1024")
      end
      unless max_attempts > 0 && max_attempts <= Int32::MAX
        raise ConfigurationError.new("RabbitMQ max_attempts must be a positive 32-bit integer")
      end
      unless max_queue_length > 0 && max_queue_length <= Int32::MAX
        raise ConfigurationError.new("RabbitMQ max_queue_length must be a positive 32-bit integer")
      end
      raise ConfigurationError.new("RabbitMQ retry_delay must be positive") unless retry_delay > 0.seconds
      @prefetch = prefetch.to_u16
      @work_pool = work_pool.to_i32
      @max_attempts = max_attempts.to_i32
      @max_queue_length = max_queue_length.to_i32
    end

    # Loads settings from `microservices.rabbitmq`. `url` is required; all
    # other keys retain the constructor defaults.
    def self.from_config(
      config : LF::ConfigService,
      prefix : String = "microservices.rabbitmq",
    ) : self
      defaults = new("amqp://guest:guest@127.0.0.1:5672")
      new(
        url: config.get("#{prefix}.url").as_s,
        prefetch: config.get("#{prefix}.prefetch", defaults.prefetch.to_i),
        work_pool: config.get("#{prefix}.work_pool", defaults.work_pool),
        max_attempts: config.get("#{prefix}.max_attempts", defaults.max_attempts),
        max_queue_length: config.get("#{prefix}.max_queue_length", defaults.max_queue_length),
        retry_delay: config.get(
          "#{prefix}.retry_delay_ms",
          defaults.retry_delay.total_milliseconds.to_i64,
        ).milliseconds,
      )
    end
  end

  class ConfigurationError < LF::Microservices::Error
  end

  # Transport-neutral queue declaration arguments consumed by a `Session`.
  struct QueueOptions
    getter durable : Bool
    getter exclusive : Bool
    getter auto_delete : Bool
    getter dead_letter_exchange : String?
    getter dead_letter_routing_key : String?
    getter message_ttl : Time::Span?
    getter max_length : Int32?

    def initialize(
      @durable : Bool,
      @exclusive : Bool = false,
      @auto_delete : Bool = false,
      @dead_letter_exchange : String? = nil,
      @dead_letter_routing_key : String? = nil,
      @message_ttl : Time::Span? = nil,
      @max_length : Int32? = nil,
    )
      if message_ttl.try { |ttl| ttl <= 0.seconds }
        raise ConfigurationError.new("RabbitMQ queue message TTL must be positive")
      end
      if max_length.try { |length| length <= 0 }
        raise ConfigurationError.new("RabbitMQ queue max_length must be positive")
      end
    end
  end

  # Separates publisher confirmation from mandatory-routing success.
  struct PublishResult
    getter confirmed : Bool
    getter routed : Bool

    def initialize(@confirmed : Bool, @routed : Bool)
    end
  end

  # Raw delivery metadata returned by a RabbitMQ session before Opal validates
  # UUIDs, routes, attempts, expiry, and protocol limits.
  struct BrokerDelivery
    getter token : UInt64
    getter exchange : String
    getter routing_key : String
    getter body : Bytes
    getter message_id : String?
    getter correlation_id : String?
    getter reply_to : String?
    getter content_type : String?
    getter expiration_ms : Int64?
    getter headers : Hash(String, JSON::Any)
    getter redelivered : Bool

    def initialize(
      @token : UInt64,
      @exchange : String,
      @routing_key : String,
      body : Bytes,
      @message_id : String? = nil,
      @correlation_id : String? = nil,
      @reply_to : String? = nil,
      @content_type : String? = nil,
      @expiration_ms : Int64? = nil,
      headers : Hash(String, JSON::Any) = {} of String => JSON::Any,
      @redelivered : Bool = false,
    )
      @body = body.dup
      @headers = WireValue.deep_copy(headers)
    end

    def headers : Hash(String, JSON::Any)
      WireValue.deep_copy(@headers)
    end
  end

  alias DeliveryCallback = Proc(BrokerDelivery, Nil)
  alias DisconnectCallback = Proc(Exception, Nil)

  # Narrow AMQP capability boundary used by the RabbitMQ transports. Injecting
  # a session factory keeps adapter semantics testable without a live broker.
  abstract class Session
    abstract def declare_exchange(name : String, type : String, durable : Bool = true) : Nil
    abstract def declare_queue(name : String, options : QueueOptions) : String
    abstract def bind_queue(queue : String, exchange : String, routing_key : String) : Nil
    abstract def consume(queue : String, tag : String, prefetch : UInt16, work_pool : Int32, &callback : BrokerDelivery -> Nil) : String
    abstract def cancel(consumer_tag : String) : Nil
    abstract def publish(exchange : String, publication : Publication, persistent : Bool) : PublishResult
    abstract def ack(token : UInt64) : Nil
    abstract def reject(token : UInt64, requeue : Bool) : Nil
    abstract def on_disconnect(&callback : Exception -> Nil) : Nil
    abstract def closed? : Bool
    abstract def close : Nil
  end

  alias SessionFactory = Proc(Session)

  # Thin adaptation of cloudamqp/amqp-client.cr with separate topology,
  # consumer, and publisher channels. Publishing is serialized so a mandatory
  # Basic.Return can be correlated with its publisher confirm using the
  # `message_id` property.
  class CloudAMQPSession < Session
    @connection : AMQP::Client::Connection
    @topology : AMQP::Client::Channel
    @consumer : AMQP::Client::Channel
    @publisher : AMQP::Client::Channel
    @publish_lock = Mutex.new
    @returns_lock = Mutex.new
    @returned = Set(String).new
    @disconnect_callback : DisconnectCallback?

    def initialize(url : String, @clock : Proc(Time) = -> { Microservices.utc_now })
      @connection = AMQP::Client.new(url).connect
      @topology = @connection.channel
      @consumer = @connection.channel
      @publisher = @connection.channel
      @publisher.on_return do |message|
        if message_id = message.properties.message_id
          @returns_lock.synchronize { @returned << message_id }
        end
      end
      @connection.on_disconnect do |error|
        @disconnect_callback.try(&.call(error))
      end
      @connection.on_close do |code, text|
        @disconnect_callback.try(&.call(
          AMQP::Client::Connection::ClosedException.new("#{text} (#{code})", nil),
        ))
      end
    end

    def declare_exchange(name : String, type : String, durable : Bool = true) : Nil
      @topology.exchange_declare(name, type, durable: durable)
    end

    def declare_queue(name : String, options : QueueOptions) : String
      arguments = {} of String => AMQ::Protocol::Field
      if exchange = options.dead_letter_exchange
        arguments["x-dead-letter-exchange"] = exchange
      end
      if routing_key = options.dead_letter_routing_key
        arguments["x-dead-letter-routing-key"] = routing_key
      end
      if ttl = options.message_ttl
        arguments["x-message-ttl"] = ttl.total_milliseconds.ceil.to_i64
      end
      if max_length = options.max_length
        arguments["x-max-length"] = max_length
        arguments["x-overflow"] = "reject-publish"
      end
      @topology.queue_declare(
        name,
        durable: options.durable,
        exclusive: options.exclusive,
        auto_delete: options.auto_delete,
        args: AMQP::Client::Arguments.new(arguments),
      )[:queue_name]
    end

    def bind_queue(queue : String, exchange : String, routing_key : String) : Nil
      @topology.queue_bind(queue, exchange, routing_key)
    end

    def consume(
      queue : String,
      tag : String,
      prefetch : UInt16,
      work_pool : Int32,
      &callback : BrokerDelivery -> Nil
    ) : String
      @consumer.prefetch(prefetch)
      @consumer.basic_consume(
        queue,
        tag: tag,
        no_ack: false,
        work_pool: work_pool,
      ) do |message|
        callback.call(broker_delivery(message))
      end
    end

    def cancel(consumer_tag : String) : Nil
      @consumer.basic_cancel(consumer_tag, no_wait: false)
    end

    def publish(exchange : String, publication : Publication, persistent : Bool) : PublishResult
      @publish_lock.synchronize do
        message_id = publication.message_id.to_s
        @returns_lock.synchronize { @returned.delete(message_id) }
        confirmed = @publisher.basic_publish_confirm(
          publication.body,
          exchange,
          publication.routing_key,
          mandatory: publication.mandatory,
          props: properties(publication, persistent),
        )

        # AMQP requires Basic.Return to precede the publisher confirm. The
        # library schedules return callbacks on a separate fiber, so yield once
        # after confirm processing before observing the correlated return set.
        Fiber.yield
        returned = @returns_lock.synchronize { @returned.delete(message_id) }
        PublishResult.new(confirmed, !returned)
      end
    end

    def ack(token : UInt64) : Nil
      @consumer.basic_ack(token)
    end

    def reject(token : UInt64, requeue : Bool) : Nil
      @consumer.basic_reject(token, requeue: requeue)
    end

    def on_disconnect(&callback : Exception -> Nil) : Nil
      @disconnect_callback = callback
    end

    def closed? : Bool
      @connection.closed?
    end

    def close : Nil
      @connection.close unless @connection.closed?
    end

    private def properties(publication : Publication, persistent : Bool) : AMQ::Protocol::Properties
      expiration = publication.expires_at.try do |expires_at|
        remaining = (expires_at - @clock.call).total_milliseconds.ceil.to_i64
        Math.max(remaining, 0_i64).to_s
      end
      fields = {} of String => AMQ::Protocol::Field
      publication.headers.each { |key, value| fields[key] = value }
      AMQ::Protocol::Properties.new(
        content_type: publication.content_type,
        headers: fields.empty? ? nil : AMQP::Client::Arguments.new(fields),
        delivery_mode: persistent ? 2_u8 : 1_u8,
        correlation_id: publication.correlation_id.try(&.to_s),
        reply_to: publication.reply_to.try(&.value),
        expiration: expiration,
        message_id: publication.message_id.to_s,
        timestamp: @clock.call,
      )
    end

    private def broker_delivery(message : AMQP::Client::DeliverMessage) : BrokerDelivery
      properties = message.properties
      headers = {} of String => JSON::Any
      properties.headers.try do |table|
        table.each do |key, value|
          headers[key] = json_header(value, key)
        end
      end
      expiration_ms = properties.expiration.try do |value|
        parsed = value.to_i64?
        unless parsed && parsed >= 0
          raise WireDecodingError.new("RabbitMQ expiration must be non-negative milliseconds")
        end
        parsed
      end
      BrokerDelivery.new(
        message.delivery_tag,
        message.exchange,
        message.routing_key,
        message.body_io.to_slice,
        message_id: properties.message_id,
        correlation_id: properties.correlation_id,
        reply_to: properties.reply_to,
        content_type: properties.content_type,
        expiration_ms: expiration_ms,
        headers: headers,
        redelivered: message.redelivered,
      )
    end

    private def json_header(value : AMQ::Protocol::Field, field : String) : JSON::Any
      case value
      when JSON::Any
        WireValue.deep_copy(value)
      when Nil
        JSON::Any.new(nil)
      when Bool
        JSON::Any.new(value)
      when Int8, UInt8, Int16, UInt16, Int32, UInt32, Int64
        JSON::Any.new(value.to_i64)
      when Float32, Float64
        number = value.to_f64
        unless number.finite?
          raise WireDecodingError.new("RabbitMQ header #{field.inspect} contains a non-finite float")
        end
        JSON::Any.new(number)
      when String
        JSON::Any.new(value)
      when AMQ::Protocol::Table
        converted = {} of String => JSON::Any
        value.each { |key, item| converted[key] = json_header(item, field) }
        JSON::Any.new(converted)
      when Hash
        JSON::Any.new(value.to_h { |key, item| {key, json_header(item, field)} })
      when Array
        JSON::Any.new(value.map { |item| json_header(item, field) })
      else
        raise WireDecodingError.new(
          "RabbitMQ header #{field.inspect} uses unsupported AMQP type #{value.class}",
        )
      end
    end
  end
end
