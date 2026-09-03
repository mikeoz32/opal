require "../application"
require "../http/autoconfig_middleware"
require "./authentication"
require "./http"

module LF::AutoConfig
  annotation Security
  end
end

module LF::Security::AutoConfig
  # Installs the authentication handler before the HTTP extension is configured.
  # Applications supply one explicit `security_authenticator` bean when they
  # need credentials; without it the application remains intentionally public.
  @[LF::ApplicationAutoConfiguration(
    enabled_by: LF::AutoConfig::Security,
    priority: 200
  )]
  class Extension
    include LF::ApplicationExtension

    def configure(context : LF::ApplicationContext) : Nil
      authenticator = if context.registered?("security_authenticator")
                        context.resolve("security_authenticator", LF::Security::Authenticator)
                      else
                        AnonymousAuthenticator.new
                      end
      handler = AuthenticationHandler.new(authenticator)
      context.register_bean(
        name: "security_context",
        scope: "prototype",
        type: LF::Security::Context
      ) do |scope|
        scope.security_context || raise LF::HTTP::InternalServerError.new("Security context not initialized")
      end
      context.register_bean(
        name: "http_autoconfig_middleware",
        type: LF::HTTP::AutoConfigMiddleware
      ) do |_scope|
        handler.as(LF::HTTP::AutoConfigMiddleware)
      end
    end

    def stop : Nil
    end
  end

  private class AnonymousAuthenticator < Authenticator
    def authenticate(request : ::HTTP::Request) : Authentication?
      nil
    end
  end
end

macro finished
  {% for klass in Object.all_subclasses %}
    {% if klass.annotation(LF::AutoConfig::Security) && !klass.annotation(LF::Application) %}
      {% raise "@[LF::AutoConfig::Security] requires @[LF::Application] on #{klass.name}" %}
    {% end %}
  {% end %}
end
