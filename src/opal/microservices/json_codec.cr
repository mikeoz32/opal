module LF::Microservices
  class JSONCodec
    REQUEST_FIELDS = Set{
      "message_id", "kind", "namespace", "service", "contract_version",
      "method", "schema_version", "created_at", "deadline_at",
      "correlation_id", "causation_id", "reply_to", "headers", "payload",
    }
    RESPONSE_BASE_FIELDS = Set{"message_id", "kind", "correlation_id", "completed_at"}
    EVENT_FIELDS         = Set{
      "message_id", "kind", "namespace", "service", "contract_version",
      "event", "schema_version", "occurred_at", "correlation_id",
      "causation_id", "headers", "payload",
    }
    ERROR_FIELDS = Set{"code", "message", "retryable", "details"}

    getter profile : ProtocolProfile

    def initialize(@profile : ProtocolProfile = ProtocolProfile.new)
    end

    def initialize(limits : MessageLimits)
      @profile = ProtocolProfile.new(limits: limits)
    end

    def limits : MessageLimits
      profile.limits
    end

    def encode_request(envelope : RPCRequestEnvelope) : Bytes
      validate_headers_for_encoding(envelope.headers)
      validate_for_encoding(envelope.payload, "payload")
      encode do |json|
        json.object do
          json.field "message_id", envelope.message_id.to_s
          json.field "kind", envelope.kind
          write_service(json, envelope.service)
          json.field "method", envelope.method
          json.field "schema_version", envelope.schema_version
          json.field "created_at", timestamp(envelope.created_at, "created_at")
          json.field "deadline_at", timestamp(envelope.deadline_at, "deadline_at")
          json.field "correlation_id", envelope.correlation_id.to_s
          json.field "causation_id" do
            if causation_id = envelope.causation_id
              json.string(causation_id.to_s)
            else
              json.null
            end
          end
          json.field "reply_to", envelope.reply_to.value
          json.field("headers") { write_value(json, JSON::Any.new(envelope.headers), "headers") }
          json.field("payload") { write_value(json, envelope.payload, "payload") }
        end
      end
    end

    def decode_request(data : Bytes | String) : RPCRequestEnvelope
      value = decode_object(data)
      require_fields(value, REQUEST_FIELDS, "RPC request")
      require_kind(value, "rpc_request", "RPC request")
      causation = optional_uuid(value["causation_id"], "causation_id")
      RPCRequestEnvelope.new(
        message_id: uuid(value["message_id"], "message_id"),
        service: service(value),
        method: string(value["method"], "method"),
        schema_version: positive_i32(value["schema_version"], "schema_version"),
        created_at: timestamp(value["created_at"], "created_at"),
        deadline_at: timestamp(value["deadline_at"], "deadline_at"),
        correlation_id: uuid(value["correlation_id"], "correlation_id"),
        causation_id: causation,
        reply_to: ReplyRoute.new(string(value["reply_to"], "reply_to")),
        headers: headers(value["headers"]),
        payload: value["payload"],
        limits: limits,
      )
    rescue error : WireLimitError
      raise error
    rescue error : WireDecodingError
      raise error
    rescue error : WireError | IdentityError
      raise WireDecodingError.new(error.message || "invalid RPC request", cause: error)
    end

    def encode_response(envelope : RPCResponseEnvelope) : Bytes
      if envelope.success?
        validate_for_encoding(envelope.result.not_nil!, "result")
      else
        validate_headers_for_encoding(envelope.error.not_nil!.details)
      end
      encode do |json|
        json.object do
          json.field "message_id", envelope.message_id.to_s
          json.field "kind", envelope.kind
          json.field "correlation_id", envelope.correlation_id.to_s
          json.field "completed_at", timestamp(envelope.completed_at, "completed_at")
          if envelope.success?
            json.field("result") { write_value(json, envelope.result.not_nil!, "result") }
          else
            error = envelope.error.not_nil!
            json.field "error" do
              json.object do
                json.field "code", error.code
                json.field "message", error.message
                json.field "retryable", error.retryable
                json.field("details") { write_value(json, JSON::Any.new(error.details), "error.details") }
              end
            end
          end
        end
      end
    end

    def decode_response(data : Bytes | String) : RPCResponseEnvelope
      value = decode_object(data)
      actual = value.keys.to_set
      missing = RESPONSE_BASE_FIELDS - actual
      raise WireDecodingError.new("RPC response is missing fields: #{missing.to_a.sort}") unless missing.empty?
      unknown = actual - (RESPONSE_BASE_FIELDS | Set{"result", "error"})
      raise WireDecodingError.new("RPC response has unknown fields: #{unknown.to_a.sort}") unless unknown.empty?
      require_kind(value, "rpc_response", "RPC response")
      has_result = value.has_key?("result")
      has_error = value.has_key?("error")
      if has_result == has_error
        raise WireDecodingError.new("RPC response must contain exactly one result/error")
      end

      common = {
        message_id:     uuid(value["message_id"], "message_id"),
        correlation_id: uuid(value["correlation_id"], "correlation_id"),
        completed_at:   timestamp(value["completed_at"], "completed_at"),
      }
      if has_result
        RPCResponseEnvelope.success(**common, result: value["result"], limits: limits)
      else
        RPCResponseEnvelope.failure(**common, error: remote_error(value["error"]), limits: limits)
      end
    rescue error : WireLimitError
      raise error
    rescue error : WireDecodingError
      raise error
    rescue error : WireError | IdentityError
      raise WireDecodingError.new(error.message || "invalid RPC response", cause: error)
    end

    def encode_event(envelope : EventEnvelope) : Bytes
      validate_headers_for_encoding(envelope.headers)
      validate_for_encoding(envelope.payload, "payload")
      encode do |json|
        json.object do
          json.field "message_id", envelope.message_id.to_s
          json.field "kind", envelope.kind
          write_service(json, envelope.source)
          json.field "event", envelope.event
          json.field "schema_version", envelope.schema_version
          json.field "occurred_at", timestamp(envelope.occurred_at, "occurred_at")
          json.field "correlation_id" do
            if correlation_id = envelope.correlation_id
              json.string(correlation_id.to_s)
            else
              json.null
            end
          end
          json.field "causation_id" do
            if causation_id = envelope.causation_id
              json.string(causation_id.to_s)
            else
              json.null
            end
          end
          json.field("headers") { write_value(json, JSON::Any.new(envelope.headers), "headers") }
          json.field("payload") { write_value(json, envelope.payload, "payload") }
        end
      end
    end

    def decode_event(data : Bytes | String) : EventEnvelope
      value = decode_object(data)
      require_fields(value, EVENT_FIELDS, "event")
      require_kind(value, "event", "event")
      EventEnvelope.new(
        message_id: uuid(value["message_id"], "message_id"),
        source: service(value),
        event: string(value["event"], "event"),
        schema_version: positive_i32(value["schema_version"], "schema_version"),
        occurred_at: timestamp(value["occurred_at"], "occurred_at"),
        correlation_id: optional_uuid(value["correlation_id"], "correlation_id"),
        causation_id: optional_uuid(value["causation_id"], "causation_id"),
        headers: headers(value["headers"]),
        payload: value["payload"],
        limits: limits,
      )
    rescue error : WireLimitError
      raise error
    rescue error : WireDecodingError
      raise error
    rescue error : WireError | IdentityError
      raise WireDecodingError.new(error.message || "invalid event", cause: error)
    end

    private def encode(& : JSON::Builder ->) : Bytes
      data = JSON.build { |json| yield json }
      if data.bytesize > limits.max_envelope_bytes
        raise WireLimitError.new("wire envelope exceeds the configured byte limit")
      end
      data.to_slice.dup
    rescue error : WireError
      raise error
    rescue error : Exception
      raise WireEncodingError.new("wire envelope is not JSON encodable", cause: error)
    end

    private def decode_object(data : Bytes | String) : Hash(String, JSON::Any)
      input = data.is_a?(String) ? data : String.new(data)
      if input.bytesize > limits.max_envelope_bytes
        raise WireLimitError.new("wire envelope exceeds the configured byte limit")
      end
      parser = JSON::PullParser.new(input)
      parser.max_nesting = limits.max_nesting_depth + 2
      value = read_value(parser, 0)
      raise WireDecodingError.new("wire data contains trailing content") unless parser.kind.eof?
      value.as_h
    rescue error : WireLimitError
      raise error
    rescue error : WireDecodingError
      raise error
    rescue error : JSON::ParseException | TypeCastError
      raise WireDecodingError.new("wire data must be one valid JSON object", cause: error)
    end

    private def read_value(parser : JSON::PullParser, depth : Int32) : JSON::Any
      if depth > limits.max_nesting_depth
        raise WireLimitError.new("wire value exceeds the nesting depth limit")
      end
      case parser.kind
      when .null?
        parser.read_null
        JSON::Any.new(nil)
      when .bool?
        JSON::Any.new(parser.read_bool)
      when .int?
        JSON::Any.new(parser.read_int)
      when .float?
        value = parser.read_float
        raise WireDecodingError.new("wire value contains a non-finite float") unless value.finite?
        JSON::Any.new(value)
      when .string?
        JSON::Any.new(parser.read_string)
      when .begin_array?
        parser.read_begin_array
        values = [] of JSON::Any
        until parser.kind.end_array?
          if values.size >= limits.max_collection_items
            raise WireLimitError.new("wire array exceeds the collection limit")
          end
          values << read_value(parser, depth + 1)
        end
        parser.read_end_array
        JSON::Any.new(values)
      when .begin_object?
        parser.read_begin_object
        values = {} of String => JSON::Any
        until parser.kind.end_object?
          if values.size >= limits.max_collection_items
            raise WireLimitError.new("wire object exceeds the collection limit")
          end
          key = parser.read_object_key
          if values.has_key?(key)
            raise WireDecodingError.new("duplicate JSON object member: #{key.inspect}")
          end
          values[key] = read_value(parser, depth + 1)
        end
        parser.read_end_object
        JSON::Any.new(values)
      else
        raise WireDecodingError.new("wire data contains an unexpected JSON token")
      end
    end

    private def write_service(json : JSON::Builder, service : ServiceIdentity) : Nil
      json.field "namespace", service.namespace
      json.field "service", service.name
      json.field "contract_version", service.contract_version
    end

    private def validate_for_encoding(value : JSON::Any, field : String) : Nil
      WireValue.validate(value, field, limits)
    rescue error : WireLimitError
      raise error
    rescue error : WireError
      raise WireEncodingError.new(error.message || "#{field} is not codec-compatible", cause: error)
    end

    private def validate_headers_for_encoding(headers : Hash(String, JSON::Any)) : Nil
      WireValue.validate_headers(headers, limits)
    rescue error : WireLimitError
      raise error
    rescue error : WireError
      raise WireEncodingError.new(error.message || "headers are not codec-compatible", cause: error)
    end

    private def write_value(json : JSON::Builder, value : JSON::Any, field : String, depth : Int32 = 0) : Nil
      WireValue.validate(value, field, limits, depth)
      case raw = value.raw
      when Hash
        json.object do
          raw.keys.sort.each do |key|
            json.field(key) { write_value(json, raw[key], field, depth + 1) }
          end
        end
      when Array
        json.array { raw.each { |item| write_value(json, item, field, depth + 1) } }
      when Nil
        json.null
      else
        raw.to_json(json)
      end
    end

    private def require_fields(value : Hash(String, JSON::Any), expected : Set(String), field : String) : Nil
      actual = value.keys.to_set
      missing = expected - actual
      unknown = actual - expected
      raise WireDecodingError.new("#{field} is missing fields: #{missing.to_a.sort}") unless missing.empty?
      raise WireDecodingError.new("#{field} has unknown fields: #{unknown.to_a.sort}") unless unknown.empty?
    end

    private def require_kind(value : Hash(String, JSON::Any), expected : String, field : String) : Nil
      raise WireDecodingError.new("#{field} kind is invalid") unless string(value["kind"], "kind") == expected
    end

    private def string(value : JSON::Any, field : String) : String
      value.as_s
    rescue TypeCastError
      raise WireDecodingError.new("#{field} must be a string")
    end

    private def positive_i32(value : JSON::Any, field : String) : Int32
      number = value.as_i64
      unless number > 0 && number <= Int32::MAX
        raise WireDecodingError.new("#{field} must be a positive 32-bit integer")
      end
      number.to_i32
    rescue TypeCastError
      raise WireDecodingError.new("#{field} must be a positive 32-bit integer")
    end

    private def uuid(value : JSON::Any, field : String) : UUID
      text = string(value, field)
      parsed = UUID.new(text)
      raise WireDecodingError.new("#{field} must use canonical UUID text") unless parsed.to_s == text
      parsed
    rescue ArgumentError
      raise WireDecodingError.new("#{field} must be a UUID")
    end

    private def optional_uuid(value : JSON::Any, field : String) : UUID?
      value.raw.nil? ? nil : uuid(value, field)
    end

    private def timestamp(value : JSON::Any, field : String) : Time
      text = string(value, field)
      unless text.ends_with?('Z') || /[+-]\d{2}:\d{2}$/.matches?(text)
        raise WireDecodingError.new("#{field} must include an explicit UTC offset")
      end
      parsed = Time::Format::RFC_3339.parse(text)
      WireValue.validate_timestamp(parsed, field)
      parsed.to_utc
    rescue error : Time::Format::Error
      raise WireDecodingError.new("#{field} must be an RFC-3339 timestamp", cause: error)
    rescue error : WireError
      raise WireDecodingError.new(error.message || "#{field} must be UTC", cause: error)
    end

    private def timestamp(value : Time, field : String) : String
      WireValue.validate_timestamp(value, field)
      digits = value.nanosecond == 0 ? 0 : 6
      value.to_utc.to_rfc3339(fraction_digits: digits)
    end

    private def service(value : Hash(String, JSON::Any)) : ServiceIdentity
      ServiceIdentity.new(
        string(value["namespace"], "namespace"),
        string(value["service"], "service"),
        positive_i32(value["contract_version"], "contract_version"),
      )
    end

    private def headers(value : JSON::Any) : Hash(String, JSON::Any)
      result = value.as_h.dup
      WireValue.validate_headers(result, limits)
      result
    rescue error : TypeCastError
      raise WireDecodingError.new("headers must be a JSON object", cause: error)
    end

    private def remote_error(value : JSON::Any) : RemoteRPCErrorData
      object = value.as_h
      require_fields(object, ERROR_FIELDS, "error")
      retryable = value = object["retryable"].raw
      unless retryable.is_a?(Bool)
        raise WireDecodingError.new("error.retryable must be boolean")
      end
      RemoteRPCErrorData.new(
        code: string(object["code"], "error.code"),
        message: string(object["message"], "error.message"),
        retryable: retryable,
        details: headers(object["details"]),
        limits: limits,
      )
    rescue error : TypeCastError
      raise WireDecodingError.new("error must be a JSON object", cause: error)
    end
  end
end
