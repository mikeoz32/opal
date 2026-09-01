require "base64"
require "json"
require "openssl/hmac"
require "./error"

module LF::LiveView
  struct Mount
    getter route : String
    getter params : Hash(String, String)
    getter resource : String

    def initialize(@route, @params, @resource)
    end
  end

  struct ChildMount
    getter type_name : String
    getter id : String
    getter parent_id : String
    getter parent_topic : String
    getter session : JSON::Any
    getter resource : String
    getter depth : Int32

    def initialize(
      @type_name,
      @id,
      @parent_id,
      @parent_topic,
      @session,
      @resource,
      @depth,
    )
    end
  end

  class MountToken
    private struct Payload
      include JSON::Serializable

      getter route : String
      getter params : Hash(String, String)
      getter resource : String
      getter issued_at : Int64

      def initialize(@route, @params, @resource, @issued_at)
      end
    end

    private struct ChildPayload
      include JSON::Serializable

      getter kind : String
      getter type_name : String
      getter id : String
      getter parent_id : String
      getter parent_topic : String
      getter session : JSON::Any
      getter resource : String
      getter depth : Int32
      getter issued_at : Int64

      def initialize(
        @type_name,
        @id,
        @parent_id,
        @parent_topic,
        @session,
        @resource,
        @depth,
        @issued_at,
        @kind = "child",
      )
      end
    end

    getter max_age : Time::Span

    def initialize(@secret : String, @max_age = 24.hours)
      if @secret.bytesize < 32
        raise ConfigurationError.new("live_view.secret must contain at least 32 bytes")
      end
      unless @max_age.positive?
        raise ConfigurationError.new("LiveView mount token max age must be positive")
      end
    end

    def sign(route : String, params : Hash(String, String), resource : String, now = Time.utc) : String
      payload = Payload.new(route, params, resource, now.to_unix_ms).to_json
      encoded = Base64.urlsafe_encode(payload, padding: false)
      "#{encoded}.#{signature(encoded)}"
    end

    def verify(token : String, now = Time.utc) : Mount
      payload = verified_payload(token, Payload, now)

      Mount.new(payload.route, payload.params, payload.resource)
    rescue error : InvalidMountTokenError
      raise error
    rescue Base64::Error | JSON::ParseException | JSON::SerializableError | ArgumentError
      raise InvalidMountTokenError.new
    end

    def sign_child(
      type_name : String,
      id : String,
      parent_id : String,
      parent_topic : String,
      session : JSON::Any,
      resource : String,
      depth : Int32,
      now = Time.utc,
    ) : String
      payload = ChildPayload.new(
        type_name,
        id,
        parent_id,
        parent_topic,
        session,
        resource,
        depth,
        now.to_unix_ms
      ).to_json
      encoded = Base64.urlsafe_encode(payload, padding: false)
      "#{encoded}.#{signature(encoded)}"
    end

    def verify_child(token : String, now = Time.utc) : ChildMount
      payload = verified_payload(token, ChildPayload, now)
      raise InvalidMountTokenError.new unless payload.kind == "child"
      ChildMount.new(
        payload.type_name,
        payload.id,
        payload.parent_id,
        payload.parent_topic,
        payload.session,
        payload.resource,
        payload.depth
      )
    rescue error : InvalidMountTokenError
      raise error
    rescue Base64::Error | JSON::ParseException | JSON::SerializableError | ArgumentError
      raise InvalidMountTokenError.new
    end

    private def split(token : String) : {String, String}
      parts = token.split('.', 2)
      raise InvalidMountTokenError.new unless parts.size == 2
      {parts[0], parts[1]}
    end

    private def signature(encoded : String) : String
      OpenSSL::HMAC.hexdigest(:sha256, @secret, encoded)
    end

    private def verified_payload(token : String, type : T.class, now : Time) : T forall T
      encoded, supplied_signature = split(token)
      unless secure_compare(signature(encoded), supplied_signature)
        raise InvalidMountTokenError.new
      end

      payload = T.from_json(String.new(Base64.decode(encoded)))
      age_ms = now.to_unix_ms - payload.issued_at
      if age_ms < -30_000 || age_ms > @max_age.total_milliseconds
        raise InvalidMountTokenError.new
      end
      payload
    end

    private def secure_compare(expected : String, supplied : String) : Bool
      return false unless expected.bytesize == supplied.bytesize

      difference = 0_u8
      expected.to_slice.each_with_index do |byte, index|
        difference |= byte ^ supplied.to_slice[index]
      end
      difference == 0
    end
  end
end
