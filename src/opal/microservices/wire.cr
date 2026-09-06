require "json"
require "uuid"

module LF::Microservices
  module WireValue
    extend self

    def deep_copy(value : JSON::Any) : JSON::Any
      case raw = value.raw
      when Hash
        JSON::Any.new(raw.to_h { |key, item| {key, deep_copy(item)} })
      when Array
        JSON::Any.new(raw.map { |item| deep_copy(item) })
      else
        value
      end
    end

    def deep_copy(values : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
      deep_copy(JSON::Any.new(values)).as_h
    end

    def validate(value : JSON::Any, field : String, limits : MessageLimits, depth : Int32 = 0) : Nil
      if depth > limits.max_nesting_depth
        raise WireLimitError.new("#{field} exceeds the nesting depth limit")
      end

      case raw = value.raw
      when Hash
        if raw.size > limits.max_collection_items
          raise WireLimitError.new("#{field} exceeds the collection limit")
        end
        raw.each do |key, item|
          raise WireError.new("#{field} keys must be non-empty strings") if key.empty?
          validate(item, field, limits, depth + 1)
        end
      when Array
        if raw.size > limits.max_collection_items
          raise WireLimitError.new("#{field} exceeds the collection limit")
        end
        raw.each { |item| validate(item, field, limits, depth + 1) }
      when Float64
        raise WireError.new("#{field} contains a non-finite float") unless raw.finite?
      end
    end

    def validate_headers(headers : Hash(String, JSON::Any), limits : MessageLimits) : Nil
      if headers.size > limits.max_header_count
        raise WireLimitError.new("headers exceed the configured count limit")
      end
      validate(JSON::Any.new(headers), "headers", limits)
      if headers.to_json.bytesize > limits.max_header_bytes
        raise WireLimitError.new("headers exceed the configured byte limit")
      end
    end

    def validate_utc(value : Time, field : String) : Nil
      raise WireError.new("#{field} must use UTC") unless value.offset == 0
    end

    def validate_timestamp(value : Time, field : String) : Nil
      validate_utc(value, field)
      unless value.nanosecond % 1_000 == 0
        raise WireError.new("#{field} must use at most microsecond precision")
      end
    end
  end

  struct RemoteRPCErrorData
    MAX_MESSAGE_CHARACTERS = 4096

    getter code : String
    getter message : String
    getter retryable : Bool
    @details : Hash(String, JSON::Any)

    def initialize(
      @code : String,
      @message : String,
      @retryable : Bool = false,
      details : Hash(String, JSON::Any) = {} of String => JSON::Any,
      limits : MessageLimits = MessageLimits.new,
    )
      raise WireError.new("remote error code must be a non-empty string") if code.empty?
      raise WireError.new("remote error message must be non-empty") if message.empty?
      if message.size > MAX_MESSAGE_CHARACTERS
        raise WireError.new("remote error message exceeds #{MAX_MESSAGE_CHARACTERS} characters")
      end
      @details = WireValue.deep_copy(details)
      WireValue.validate_headers(@details, limits)
    end

    def details : Hash(String, JSON::Any)
      WireValue.deep_copy(@details)
    end
  end

  struct RPCRequestEnvelope
    getter message_id : UUID
    getter service : ServiceIdentity
    getter method : String
    getter schema_version : Int32
    getter created_at : Time
    getter deadline_at : Time
    getter correlation_id : UUID
    getter causation_id : UUID?
    getter reply_to : ReplyRoute
    @headers : Hash(String, JSON::Any)
    @payload : JSON::Any

    def initialize(
      @message_id : UUID,
      @service : ServiceIdentity,
      @method : String,
      schema_version : Int,
      @created_at : Time,
      @deadline_at : Time,
      @correlation_id : UUID,
      @reply_to : ReplyRoute,
      @causation_id : UUID? = nil,
      headers : Hash(String, JSON::Any) = {} of String => JSON::Any,
      @payload : JSON::Any = JSON::Any.new(nil),
      limits : MessageLimits = MessageLimits.new,
    )
      target = RPCTarget.new(service, method, schema_version)
      @method = target.method
      @schema_version = target.schema_version
      WireValue.validate_timestamp(created_at, "created_at")
      WireValue.validate_timestamp(deadline_at, "deadline_at")
      if deadline_at <= created_at
        raise WireDeadlineError.new("deadline_at must be later than created_at")
      end
      @headers = WireValue.deep_copy(headers)
      @payload = WireValue.deep_copy(payload)
      WireValue.validate_headers(@headers, limits)
      WireValue.validate(@payload, "payload", limits)
    end

    def headers : Hash(String, JSON::Any)
      WireValue.deep_copy(@headers)
    end

    def payload : JSON::Any
      WireValue.deep_copy(@payload)
    end

    def kind : String
      "rpc_request"
    end
  end

  struct RPCResponseEnvelope
    getter message_id : UUID
    getter correlation_id : UUID
    getter completed_at : Time
    @result : JSON::Any?
    getter error : RemoteRPCErrorData?

    private def initialize(
      @message_id : UUID,
      @correlation_id : UUID,
      @completed_at : Time,
      @result : JSON::Any?,
      @error : RemoteRPCErrorData?,
      @has_result : Bool,
      limits : MessageLimits,
    )
      WireValue.validate_timestamp(completed_at, "completed_at")
      if @has_result
        @result = WireValue.deep_copy(@result.not_nil!)
        WireValue.validate(@result.not_nil!, "result", limits)
      end
    end

    def self.success(
      message_id : UUID,
      correlation_id : UUID,
      completed_at : Time,
      result : JSON::Any = JSON::Any.new(nil),
      limits : MessageLimits = MessageLimits.new,
    ) : self
      new(message_id, correlation_id, completed_at, result, nil, true, limits)
    end

    def self.failure(
      message_id : UUID,
      correlation_id : UUID,
      completed_at : Time,
      error : RemoteRPCErrorData,
      limits : MessageLimits = MessageLimits.new,
    ) : self
      new(message_id, correlation_id, completed_at, nil, error, false, limits)
    end

    def success? : Bool
      @has_result
    end

    def result : JSON::Any?
      @result.try { |value| WireValue.deep_copy(value) }
    end

    def kind : String
      "rpc_response"
    end
  end

  struct EventEnvelope
    getter message_id : UUID
    getter source : ServiceIdentity
    getter event : String
    getter schema_version : Int32
    getter occurred_at : Time
    getter correlation_id : UUID?
    getter causation_id : UUID?
    @headers : Hash(String, JSON::Any)
    @payload : JSON::Any

    def initialize(
      @message_id : UUID,
      @source : ServiceIdentity,
      @event : String,
      schema_version : Int,
      @occurred_at : Time,
      @correlation_id : UUID? = nil,
      @causation_id : UUID? = nil,
      headers : Hash(String, JSON::Any) = {} of String => JSON::Any,
      @payload : JSON::Any = JSON::Any.new(nil),
      limits : MessageLimits = MessageLimits.new,
    )
      identity = EventIdentity.new(source, event, schema_version)
      @event = identity.event
      @schema_version = identity.schema_version
      WireValue.validate_timestamp(occurred_at, "occurred_at")
      @headers = WireValue.deep_copy(headers)
      @payload = WireValue.deep_copy(payload)
      WireValue.validate_headers(@headers, limits)
      WireValue.validate(@payload, "payload", limits)
    end

    def headers : Hash(String, JSON::Any)
      WireValue.deep_copy(@headers)
    end

    def payload : JSON::Any
      WireValue.deep_copy(@payload)
    end

    def kind : String
      "event"
    end
  end
end
