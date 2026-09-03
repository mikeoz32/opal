require "jwt"
require "jwt/jwks"
require "./authentication"

module LF::Security
  # JWT adapters are deliberately opt-in. Applications that use them add
  # `crystal-community/jwt` to their own shard.yml and require this file.
  module JWTSupport
    def self.bearer_token(request : ::HTTP::Request) : String?
      value = request.headers["Authorization"]?
      return nil unless value
      return nil unless value.starts_with?("Bearer ")

      token = value[7..]
      raise InvalidCredentials.new("Missing bearer token") if token.empty?
      token
    end

    def self.principal(
      payload : JSON::Any,
      authority_claim = "scope",
    ) : Principal
      claims = payload.as_h
      subject = claims["sub"]?.try(&.as_s?) || raise InvalidCredentials.new("JWT subject is required")
      Principal.new(subject, authorities(claims, authority_claim), claims)
    rescue TypeCastError
      raise InvalidCredentials.new("Invalid JWT claims")
    end

    private def self.authorities(
      claims : Hash(String, JSON::Any),
      authority_claim : String,
    ) : Array(String)
      value = claims[authority_claim]?
      return [] of String unless value

      if scope = value.as_s?
        scope.split(/\s+/).reject(&.empty?)
      elsif values = value.as_a?
        values.compact_map(&.as_s?)
      else
        raise InvalidCredentials.new("JWT authority claim must be a string or array")
      end
    end
  end

  # Validates a bearer token against one pinned key and one pinned algorithm.
  # The token's `alg` header is never used to select a verifier.
  class JWTAuthenticator < Authenticator
    def initialize(
      @key : String,
      @algorithm : JWT::Algorithm,
      @issuer : String? = nil,
      @audience : String? = nil,
      @authority_claim = "scope",
    )
      raise ConfigurationError.new("JWT algorithm must not be none") if @algorithm == JWT::Algorithm::None
    end

    def authenticate(request : ::HTTP::Request) : Authentication?
      token = JWTSupport.bearer_token(request)
      return nil unless token

      payload, _header = JWT.decode(token, @key, @algorithm)
      validate_issuer_and_audience(payload)
      Authentication.new(
        JWTSupport.principal(payload, @authority_claim),
        AuthenticationMethod::BearerToken
      )
    rescue error : JWT::Error
      raise InvalidCredentials.new("Invalid bearer token")
    end

    private def validate_issuer_and_audience(payload : JSON::Any) : Nil
      claims = payload.as_h
      if issuer = @issuer
        raise InvalidCredentials.new("Invalid JWT issuer") unless claims["iss"]?.try(&.as_s?) == issuer
      end
      if audience = @audience
        value = claims["aud"]?
        matches = value.try(&.as_s?) == audience || value.try(&.as_a?).try(&.any? { |item| item.as_s? == audience })
        raise InvalidCredentials.new("Invalid JWT audience") unless matches
      end
    rescue TypeCastError
      raise InvalidCredentials.new("Invalid JWT claims")
    end
  end

  # Uses the maintained JWT shard's HTTPS-only OIDC discovery and JWKS cache.
  # It accepts only bearer tokens and validates issuer, audience, signature,
  # expiry, and not-before claims before producing an Opal principal.
  class OIDCAuthenticator < Authenticator
    def initialize(
      @issuer : String,
      @audience : String | Array(String),
      @authority_claim = "scope",
      cache_ttl = JWT::JWKS::DEFAULT_CACHE_TTL,
      leeway = JWT::JWKS::DEFAULT_LEEWAY,
    )
      @validator = JWT::JWKS.new(cache_ttl: cache_ttl, leeway: leeway)
    end

    def authenticate(request : ::HTTP::Request) : Authentication?
      token = JWTSupport.bearer_token(request)
      return nil unless token

      payload = @validator.validate(token, issuer: @issuer, audience: @audience)
      raise InvalidCredentials.new("Invalid OIDC token") unless payload
      Authentication.new(JWTSupport.principal(payload, @authority_claim), AuthenticationMethod::OIDC)
    rescue error : JWT::Error
      raise InvalidCredentials.new("Invalid OIDC token")
    end
  end
end
