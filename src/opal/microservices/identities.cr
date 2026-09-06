require "random/secure"

module LF::Microservices
  MAX_AMQP_NAME_BYTES = 255
  ALIAS_PATTERN       = /^[a-z][a-z0-9_-]{0,62}$/

  def self.validate_alias(value : String, field : String = "alias") : String
    unless ALIAS_PATTERN.matches?(value)
      raise IdentityError.new("#{field} must match [a-z][a-z0-9_-]{0,62}")
    end
    value
  end

  def self.validate_version(value : Int, field : String = "version") : Int32
    unless value > 0 && value <= Int32::MAX
      raise IdentityError.new("#{field} must be a positive 32-bit integer")
    end
    value.to_i32
  end

  def self.validate_amqp_name(value : String, field : String) : String
    if value.bytesize > MAX_AMQP_NAME_BYTES
      raise IdentityError.new("#{field} exceeds RabbitMQ's 255-byte name limit")
    end
    value
  end

  # Returns the current UTC time at the microsecond precision supported by
  # protocol v1 and Tori's Python datetime values.
  def self.utc_now : Time
    now = Time.utc
    Time.unix_ns(now.to_unix_ns - now.nanosecond % 1_000)
  end

  struct ServiceIdentity
    getter namespace : String
    getter name : String
    getter contract_version : Int32

    def initialize(@namespace : String, @name : String, contract_version : Int)
      Microservices.validate_alias(namespace, "namespace")
      Microservices.validate_alias(name, "name")
      @contract_version = Microservices.validate_version(contract_version, "contract_version")
      Microservices.validate_amqp_name(label, "service label")
    end

    def label : String
      "#{namespace}.#{name}.v#{contract_version}"
    end
  end

  struct RPCTarget
    getter service : ServiceIdentity
    getter method : String
    getter schema_version : Int32

    def initialize(@service : ServiceIdentity, @method : String, schema_version : Int)
      Microservices.validate_alias(method, "method")
      @schema_version = Microservices.validate_version(schema_version, "schema_version")
      Microservices.validate_amqp_name(routing_key, "RPC routing key")
    end

    def routing_key : String
      "#{service.label}.#{method}"
    end
  end

  struct EventIdentity
    getter source : ServiceIdentity
    getter event : String
    getter schema_version : Int32

    def initialize(@source : ServiceIdentity, @event : String, schema_version : Int)
      Microservices.validate_alias(event, "event")
      @schema_version = Microservices.validate_version(schema_version, "schema_version")
      Microservices.validate_amqp_name(routing_key, "event routing key")
    end

    def routing_key : String
      "#{event}.v#{schema_version}"
    end
  end

  struct ReplyRoute
    getter value : String

    def initialize(@value : String)
      unless /^[a-z][a-z0-9_-]*(?:\.[a-z][a-z0-9_-]*)*\.[0-9a-f]{32}$/.matches?(value)
        raise WireError.new(
          "reply route must contain a safe prefix and 32 lowercase hexadecimal characters"
        )
      end
      Microservices.validate_amqp_name(value, "reply route")
    end

    def self.generate(prefix : String = "reply") : self
      new("#{prefix}.#{Random::Secure.hex(16)}")
    end
  end

  struct MessageLimits
    getter max_envelope_bytes : Int32
    getter max_header_count : Int32
    getter max_header_bytes : Int32
    getter max_nesting_depth : Int32
    getter max_collection_items : Int32

    def initialize(
      max_envelope_bytes : Int = 1024 * 1024,
      max_header_count : Int = 64,
      max_header_bytes : Int = 64 * 1024,
      max_nesting_depth : Int = 64,
      max_collection_items : Int = 10_000,
    )
      @max_envelope_bytes = positive_i32(max_envelope_bytes, "max_envelope_bytes")
      @max_header_count = positive_i32(max_header_count, "max_header_count")
      @max_header_bytes = positive_i32(max_header_bytes, "max_header_bytes")
      @max_nesting_depth = positive_i32(max_nesting_depth, "max_nesting_depth")
      @max_collection_items = positive_i32(max_collection_items, "max_collection_items")
    end

    private def positive_i32(value : Int, field : String) : Int32
      unless value > 0 && value <= Int32::MAX
        raise WireLimitError.new("#{field} must be a positive 32-bit integer")
      end
      value.to_i32
    end
  end
end
