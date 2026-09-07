require "http/request"
require "json"
require "set"
require "./error"

module LF::Security
  # The credential scheme that produced an `Authentication` result.
  enum AuthenticationMethod
    Anonymous
    APIKey
    Session
    BearerToken
    OIDC
  end

  # An immutable application identity. Claims retain issuer-specific data, but
  # authorization itself uses the explicit authority set.
  class Principal
    getter subject : String

    @authorities : Set(String)
    @claims : Hash(String, JSON::Any)

    def initialize(
      @subject : String,
      authorities : Enumerable(String) = [] of String,
      claims = {} of String => JSON::Any,
    )
      @authorities = authorities.to_set
      @claims = claims.dup
      raise ArgumentError.new("Security principal subject must not be empty") if @subject.empty?
    end

    def authorities : Set(String)
      @authorities.dup
    end

    def claims : Hash(String, JSON::Any)
      @claims.dup
    end

    # Returns whether this principal has the exact application authority.
    # Authorities are explicit strings, not inferred from issuer-specific
    # claims, so application authorization remains portable across authenticators.
    def authorized_for?(authority : String) : Bool
      @authorities.includes?(authority)
    end
  end

  # Immutable authentication result created by an `Authenticator`.
  #
  # Session authentication can carry a CSRF token. API-key and bearer-token
  # authentication intentionally cannot, because CSRF is a browser-cookie
  # concern rather than a credential presented explicitly by the client.
  class Authentication
    getter principal : Principal?
    getter method : AuthenticationMethod
    getter csrf_token : String?

    def initialize(
      @principal : Principal? = nil,
      @method = AuthenticationMethod::Anonymous,
      @csrf_token : String? = nil,
    )
      if @principal.nil? && @method != AuthenticationMethod::Anonymous
        raise ArgumentError.new("Authenticated security contexts require a principal")
      end
      if @method != AuthenticationMethod::Session && @csrf_token
        raise ArgumentError.new("Only session authentication can carry a CSRF token")
      end
    end

    def authenticated? : Bool
      !@principal.nil?
    end

    def session? : Bool
      @method == AuthenticationMethod::Session
    end
  end

  # A request or WebSocket-handshake security result. It is immutable after
  # authentication, so guards observe one identity for their whole execution.
  class Context
    getter authentication : Authentication

    def initialize(@authentication = Authentication.new)
    end

    def authenticated? : Bool
      @authentication.authenticated?
    end

    def principal : Principal
      @authentication.principal || raise InvalidCredentials.new("Authentication required")
    end
  end

  # An authenticator abstains (`nil`) when its credential is absent and raises
  # InvalidCredentials only when a credential for its scheme is malformed or
  # fails verification. That makes chains predictable and prevents a bad API
  # key from silently falling through to an anonymous request.
  abstract class Authenticator
    abstract def authenticate(request : ::HTTP::Request) : Authentication?
  end

  # Tries authenticators in order.
  #
  # An authenticator returns `nil` only when its credential is absent. A present
  # but invalid credential raises, preventing a malformed API key or bearer
  # token from silently falling through to anonymous access.
  class AuthenticatorChain < Authenticator
    def initialize(@authenticators : Array(Authenticator))
      raise ConfigurationError.new("Authentication chain must contain at least one authenticator") if @authenticators.empty?
    end

    def authenticate(request : ::HTTP::Request) : Authentication?
      @authenticators.each do |authenticator|
        if authentication = authenticator.authenticate(request)
          return authentication
        end
      end
      nil
    end
  end

  # Compares two equal-length secrets without an early-exit byte comparison.
  # This is used for credentials such as API keys; callers must still reject a
  # length mismatch before treating the supplied value as authenticated.
  def self.secure_compare(expected : String, supplied : String) : Bool
    return false unless expected.bytesize == supplied.bytesize

    difference = 0_u8
    expected.to_slice.each_with_index do |byte, index|
      difference |= byte ^ supplied.to_slice[index]
    end
    difference == 0
  end
end
