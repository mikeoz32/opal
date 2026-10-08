require "http/client"

module LF::Security
  private class OIDCValidator < ::JWT::JWKS
    private struct CachedHTTPResponse(T)
      getter value : T
      getter expires_at : Time

      def initialize(@value : T, ttl : Time::Span)
        @expires_at = Time.utc + ttl
      end

      def expired? : Bool
        Time.utc >= @expires_at
      end
    end

    @expected_issuer_uri : URI
    @http_metadata_cache : CachedHTTPResponse(::JWT::JWKS::OIDCMetadata)? = nil
    @http_jwks_cache = Hash(String, CachedHTTPResponse(::JWT::JWKS::JWKSet)).new
    @http_cache_mutex = Mutex.new

    def initialize(
      @expected_issuer : String,
      @allow_insecure_http : Bool,
      cache_ttl : Time::Span,
      leeway : Time::Span,
    )
      @expected_issuer_uri = URI.parse(@expected_issuer)
      super(cache_ttl: cache_ttl, leeway: leeway)
    end

    def fetch_oidc_metadata(issuer : String) : ::JWT::JWKS::OIDCMetadata
      unless issuer == @expected_issuer
        raise ::JWT::DecodeError.new("Token issuer does not match configured OIDC issuer")
      end

      issuer_uri = URI.parse(issuer)
      return super unless issuer_uri.scheme == "http"

      unless @allow_insecure_http
        raise ::JWT::DecodeError.new("OIDC issuer must use HTTPS")
      end

      @http_cache_mutex.synchronize do
        if cached = @http_metadata_cache
          return cached.value unless cached.expired?
        end

        url = "#{issuer.rstrip("/")}/.well-known/openid-configuration"
        uri = URI.parse(url)
        client = ::HTTP::Client.new(uri)
        client.connect_timeout = 3.seconds
        client.read_timeout = 5.seconds
        begin
          response = client.get(uri.request_target)
          unless response.success?
            raise ::JWT::DecodeError.new("Failed to fetch OIDC metadata from #{url}: #{response.status}")
          end

          metadata = ::JWT::JWKS::OIDCMetadata.from_json(response.body)
          @http_metadata_cache = CachedHTTPResponse.new(metadata, @cache_ttl)
          metadata
        ensure
          client.close
        end
      end
    end

    def fetch_jwks(jwks_uri : String, force_refresh : Bool = false) : ::JWT::JWKS::JWKSet
      uri = URI.parse(jwks_uri)
      if @expected_issuer_uri.scheme == "http" && !same_origin?(uri)
        raise ::JWT::DecodeError.new("JWKS URI must match the configured OIDC issuer origin")
      end

      return super unless uri.scheme == "http"

      unless @allow_insecure_http && same_origin?(uri)
        raise ::JWT::DecodeError.new("HTTP JWKS URI must match the configured OIDC issuer origin")
      end

      @http_cache_mutex.synchronize do
        if !force_refresh
          if cached = @http_jwks_cache[jwks_uri]?
            return cached.value unless cached.expired?
          end
        end

        client = ::HTTP::Client.new(uri)
        client.connect_timeout = 3.seconds
        client.read_timeout = 5.seconds
        begin
          response = client.get(uri.request_target)
          unless response.success?
            raise ::JWT::DecodeError.new("Failed to fetch JWKS from #{jwks_uri}: #{response.status}")
          end

          jwks = ::JWT::JWKS::JWKSet.from_json(response.body)
          ttl = parse_max_age(response.headers["Cache-Control"]?) || @cache_ttl
          @http_jwks_cache[jwks_uri] = CachedHTTPResponse.new(jwks, ttl)
          jwks
        ensure
          client.close
        end
      end
    end

    def clear_cache : Nil
      @http_cache_mutex.synchronize do
        @http_metadata_cache = nil
        @http_jwks_cache.clear
      end
      super
    end

    private def same_origin?(uri : URI) : Bool
      uri.scheme == @expected_issuer_uri.scheme &&
        uri.host.try(&.downcase) == @expected_issuer_uri.host.try(&.downcase) &&
        effective_port(uri) == effective_port(@expected_issuer_uri)
    end

    private def effective_port(uri : URI) : Int32?
      uri.port || case uri.scheme
      when "http"
        80
      when "https"
        443
      else
        nil
      end
    end

    private def parse_max_age(cache_control : String?) : Time::Span?
      return unless cache_control
      if match = cache_control.match(/max-age=(\d+)/i)
        match[1].to_i.seconds
      end
    end
  end
end
