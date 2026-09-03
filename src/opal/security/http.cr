require "http/server"
require "../http/autoconfig_middleware"
require "../http/execution_pipeline"
require "../http/errors"
require "./authentication"

class HTTP::Server::Context
  property security_context : LF::Security::Context?
end

module LF::HTTP
  struct ExecutionContext
    def security : LF::Security::Context
      @http_context.security_context || LF::Security::Context.new
    end
  end
end

module LF::Security
  # Authenticates once at the transport boundary. Its result is attached to the
  # HTTP server context, which is the same context later used for a WebSocket
  # upgrade and LiveView authorization.
  class AuthenticationHandler
    include ::HTTP::Handler
    include LF::HTTP::AutoConfigMiddleware

    def initialize(@authenticator : Authenticator)
    end

    def call(context : ::HTTP::Server::Context) : Nil
      authentication = @authenticator.authenticate(context.request) || Authentication.new
      security_context = Context.new(authentication)
      context.security_context = security_context
      context.dependency_scope.try { |scope| scope.security_context = security_context }
      context.dependency_scope_initializer = ->(scope : LF::DI::Container) {
        scope.security_context = security_context
      }
      call_next(context)
    rescue error : InvalidCredentials
      context.response.status = ::HTTP::Status::UNAUTHORIZED
      context.response.headers["WWW-Authenticate"] = "Bearer"
      context.response.content_type = "text/plain"
      context.response.print "Unauthorized"
    end
  end

  # Reuses the existing controller, WebSocket, and LiveView Guard contract.
  # An anonymous request is challenged; an authenticated request is allowed.
  @[LF::DI::Service]
  class AuthenticatedGuard < LF::HTTP::Guard
    def can_activate(context : LF::HTTP::ExecutionContext) : Bool
      raise LF::HTTP::Unauthorized.new unless context.security.authenticated?
      true
    end
  end

  # Base class for application-defined authority checks. Keep policy decisions
  # in regular Crystal code instead of introducing a runtime expression DSL.
  abstract class AuthorityGuard < LF::HTTP::Guard
    abstract def required_authorities : Enumerable(String)

    def can_activate(context : LF::HTTP::ExecutionContext) : Bool
      raise LF::HTTP::Unauthorized.new unless context.security.authenticated?
      required_authorities.all? { |authority| context.security.principal.authorized_for?(authority) }
    end
  end

  # Applies CSRF only to unsafe requests authenticated by SignedSession. Token
  # APIs remain unaffected because bearer and API-key identities are not
  # cookie-authenticated.
  @[LF::DI::Service]
  class CSRFInterceptor < LF::HTTP::Interceptor
    SAFE_METHODS = {"GET", "HEAD", "OPTIONS", "TRACE"}
    @header = "X-CSRF-Token"

    def intercept(
      context : LF::HTTP::ExecutionContext,
      call_next : LF::HTTP::CallHandler,
    ) : LF::HTTP::Response
      authentication = context.security.authentication
      if authentication.session? && !SAFE_METHODS.includes?(context.request.method)
        expected = authentication.csrf_token || raise LF::HTTP::Forbidden.new("CSRF token unavailable")
        supplied = context.request.headers[@header]? || ""
        unless Security.secure_compare(expected, supplied)
          raise LF::HTTP::Forbidden.new("Invalid CSRF token")
        end
      end
      call_next.call
    end
  end
end
