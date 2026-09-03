require "base64"
require "http/cookie"
require "http/request"
require "json"
require "openssl/hmac"
require "./authentication"

module LF::Security
  # A signed, stateless browser session. The payload is authenticated, not
  # encrypted: claims must therefore be non-sensitive. The issued CSRF token is
  # returned to application code and is checked by CSRFInterceptor on unsafe
  # cookie-authenticated requests.
  class SignedSession < Authenticator
    struct Issued
      getter cookie : ::HTTP::Cookie
      getter csrf_token : String

      def initialize(@cookie, @csrf_token)
      end
    end

    private struct Payload
      include JSON::Serializable

      getter subject : String
      getter authorities : Array(String)
      getter claims : Hash(String, JSON::Any)
      getter csrf_token : String
      getter issued_at : Int64
      getter expires_at : Int64

      def initialize(
        @subject,
        @authorities,
        @claims,
        @csrf_token,
        @issued_at,
        @expires_at,
      )
      end
    end

    getter cookie_name : String
    getter lifetime : Time::Span

    def initialize(
      @secret : String,
      @cookie_name = "__Host-opal_session",
      @lifetime = 8.hours,
      @same_site = ::HTTP::Cookie::SameSite::Lax,
    )
      if @secret.bytesize < 32
        raise ConfigurationError.new("Security session secret must contain at least 32 bytes")
      end
      raise ConfigurationError.new("Security session lifetime must be positive") unless @lifetime.positive?
    end

    def issue(principal : Principal, now = Time.utc) : Issued
      csrf_token = Random::Secure.urlsafe_base64(32)
      expires_at = now + @lifetime
      payload = Payload.new(
        principal.subject,
        principal.authorities.to_a.sort,
        principal.claims,
        csrf_token,
        now.to_unix_ms,
        expires_at.to_unix_ms,
      )
      token = sign(payload.to_json)
      cookie = ::HTTP::Cookie.new(
        @cookie_name,
        token,
        path: "/",
        secure: true,
        http_only: true,
        samesite: @same_site,
        max_age: @lifetime,
      )
      Issued.new(cookie, csrf_token)
    end

    def authenticate(request : ::HTTP::Request) : Authentication?
      token = request.cookies[@cookie_name]?.try(&.value)
      return nil unless token

      payload = verify(token)
      principal = Principal.new(payload.subject, payload.authorities, payload.claims)
      Authentication.new(principal, AuthenticationMethod::Session, payload.csrf_token)
    end

    private def sign(payload : String) : String
      encoded = Base64.urlsafe_encode(payload, padding: false)
      "#{encoded}.#{signature(encoded)}"
    end

    private def verify(token : String, now = Time.utc) : Payload
      encoded, supplied_signature = split(token)
      unless Security.secure_compare(signature(encoded), supplied_signature)
        raise InvalidCredentials.new("Invalid session signature")
      end

      payload = Payload.from_json(String.new(Base64.decode(encoded)))
      now_ms = now.to_unix_ms
      if payload.issued_at > now_ms + 30_000 || payload.expires_at <= now_ms
        raise InvalidCredentials.new("Expired session")
      end
      payload
    rescue error : InvalidCredentials
      raise error
    rescue Base64::Error | JSON::ParseException | JSON::SerializableError | ArgumentError
      raise InvalidCredentials.new("Invalid session")
    end

    private def split(token : String) : {String, String}
      parts = token.split('.', 2)
      raise InvalidCredentials.new("Invalid session") unless parts.size == 2
      {parts[0], parts[1]}
    end

    private def signature(encoded : String) : String
      OpenSSL::HMAC.hexdigest(:sha256, @secret, encoded)
    end
  end
end
