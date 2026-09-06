require "../config_service"

module LF::Microservices
  # Physical broker names are deployment configuration, not logical service
  # identity. These defaults intentionally match tori-py wire version 1.
  struct TopologyConfig
    MAX_EXCHANGE_NAME_BYTES = 127

    getter rpc_exchange : String
    getter rpc_queue_prefix : String
    getter event_exchange_prefix : String
    getter event_queue_prefix : String
    getter reply_queue_prefix : String
    getter dead_letter_exchange : String
    getter retry_exchange_prefix : String

    def initialize(
      @rpc_exchange : String = "tori_py.rpc",
      @rpc_queue_prefix : String = "tori_py.rpc",
      @event_exchange_prefix : String = "tori_py.events",
      @event_queue_prefix : String = "tori_py.event",
      @reply_queue_prefix : String = "reply",
      @dead_letter_exchange : String = "tori_py.dead-letter",
      @retry_exchange_prefix : String = "tori_py.retry",
    )
      validate_exchange(rpc_exchange, "RPC exchange")
      validate_prefix(rpc_queue_prefix, "RPC queue prefix")
      validate_prefix(event_exchange_prefix, "event exchange prefix")
      validate_prefix(event_queue_prefix, "event queue prefix")
      validate_prefix(reply_queue_prefix, "reply queue prefix")
      validate_exchange(dead_letter_exchange, "dead-letter exchange")
      validate_exchange(retry_exchange_prefix, "retry exchange")
    end

    def self.from_config(config : LF::ConfigService, prefix : String = "microservices.topology") : self
      defaults = new
      new(
        rpc_exchange: config.get("#{prefix}.rpc_exchange", defaults.rpc_exchange),
        rpc_queue_prefix: config.get("#{prefix}.rpc_queue_prefix", defaults.rpc_queue_prefix),
        event_exchange_prefix: config.get("#{prefix}.event_exchange_prefix", defaults.event_exchange_prefix),
        event_queue_prefix: config.get("#{prefix}.event_queue_prefix", defaults.event_queue_prefix),
        reply_queue_prefix: config.get("#{prefix}.reply_queue_prefix", defaults.reply_queue_prefix),
        dead_letter_exchange: config.get("#{prefix}.dead_letter_exchange", defaults.dead_letter_exchange),
        retry_exchange_prefix: config.get("#{prefix}.retry_exchange_prefix", defaults.retry_exchange_prefix),
      )
    end

    def rpc_queue(service : ServiceIdentity) : String
      bounded_name("#{rpc_queue_prefix}.#{service.label}", "RPC queue")
    end

    def rpc_binding(service : ServiceIdentity) : String
      bounded_name("#{service.label}.*", "RPC binding")
    end

    def event_exchange(source : ServiceIdentity) : String
      bounded_exchange("#{event_exchange_prefix}.#{source.label}", "event exchange")
    end

    def event_queue_base(identity : EventIdentity) : String
      bounded_name(
        "#{event_queue_prefix}.#{identity.source.label}.#{identity.routing_key}",
        "event queue base"
      )
    end

    def reply_route(token : String = Random::Secure.hex(16)) : ReplyRoute
      unless /^[0-9a-f]{32}$/.matches?(token)
        raise TopologyError.new("reply token must contain 32 lowercase hexadecimal characters")
      end
      ReplyRoute.new(bounded_name("#{reply_queue_prefix}.#{token}", "reply route"))
    end

    private def validate_prefix(value : String, field : String) : Nil
      unless /^[a-z][a-z0-9_-]*(?:\.[a-z][a-z0-9_-]*)*$/.matches?(value)
        raise TopologyError.new("#{field} must use lowercase ASCII name segments")
      end
      bounded_name(value, field)
    end

    private def validate_exchange(value : String, field : String) : Nil
      validate_prefix(value, field)
      bounded_exchange(value, field)
    end

    private def bounded_name(value : String, field : String) : String
      if value.bytesize > MAX_AMQP_NAME_BYTES
        raise TopologyError.new("#{field} exceeds RabbitMQ's 255-byte name limit")
      end
      value
    end

    private def bounded_exchange(value : String, field : String) : String
      if value.bytesize > MAX_EXCHANGE_NAME_BYTES
        raise TopologyError.new("#{field} exceeds RabbitMQ's 127-byte exchange limit")
      end
      value
    end
  end

  struct ProtocolProfile
    VERSION = 1

    getter version : Int32
    getter rpc_content_type : String
    getter event_content_type : String
    getter topology : TopologyConfig
    getter limits : MessageLimits

    def initialize(
      @version : Int32 = VERSION,
      @rpc_content_type : String = "application/vnd.opal-tori.rpc+json;version=1",
      @event_content_type : String = "application/vnd.opal-tori.event+json;version=1",
      @topology : TopologyConfig = TopologyConfig.new,
      @limits : MessageLimits = MessageLimits.new,
    )
      raise WireError.new("unsupported protocol version: #{version}") unless version == VERSION
      raise WireError.new("RPC content type must not be empty") if rpc_content_type.empty?
      raise WireError.new("event content type must not be empty") if event_content_type.empty?
    end
  end
end
