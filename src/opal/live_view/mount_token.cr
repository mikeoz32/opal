require "base64"
require "json"
require "openssl/hmac"

module LF::LiveView
  struct Mount
    getter route : String
    getter params : Hash(String, String)
    getter resource : String

    def initialize(@route, @params, @resource)
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
      encoded, supplied_signature = split(token)
      unless secure_compare(signature(encoded), supplied_signature)
        raise InvalidMountTokenError.new
      end

      payload = Payload.from_json(String.new(Base64.decode(encoded)))
      age_ms = now.to_unix_ms - payload.issued_at
      if age_ms < -30_000 || age_ms > @max_age.total_milliseconds
        raise InvalidMountTokenError.new
      end

      Mount.new(payload.route, payload.params, payload.resource)
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
