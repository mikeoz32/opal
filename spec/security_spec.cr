require "./spec_helper"
require "../src/opal"
require "../src/opal/security"

@[LF::DI::Service]
class SecuritySpecProjectReadGuard < LF::Security::AuthorityGuard
  def required_authorities : Enumerable(String)
    ["projects:read"]
  end
end

@[LF::HTTP::UseGuards(LF::Security::AuthenticatedGuard)]
class SecuritySpecController
  include LF::HTTP::Controller

  @[LF::HTTP::Controller::Get("/secured")]
  def secured : String
    "secured"
  end

  @[LF::HTTP::Controller::Get("/authority")]
  @[LF::HTTP::UseGuards(SecuritySpecProjectReadGuard)]
  def authority : String
    "authorized"
  end

  @[LF::HTTP::Controller::Post("/session")]
  @[LF::HTTP::UseInterceptors(LF::Security::CSRFInterceptor)]
  def session : String
    "changed"
  end
end

private def security_spec_app(authenticator : LF::Security::Authenticator) : {::HTTP::Handler, LF::DI::DefaultContainer}
  root = LF::DI::DefaultContainer.new
  root.register(LF::DI::ServiceConfiguration.new)
  app = LF::HTTP::App.new do |router|
    SecuritySpecController.setup_routes(router, root)
  end
  handler = HTTP::Server.build_middleware([
    LF::Security::AuthenticationHandler.new(authenticator),
    app,
  ])
  {handler, root}
end

private def call_security_spec_app(
  handler : ::HTTP::Handler,
  root : LF::DI::DefaultContainer,
  path : String,
  method = "GET",
  headers = HTTP::Headers.new,
) : HTTP::Client::Response
  io = IO::Memory.new
  context = HTTP::Server::Context.new(
    HTTP::Request.new(method, path, headers),
    HTTP::Server::Response.new(io)
  )
  scope = root.enter_scope("request")
  context.dependency_scope = scope

  handler.call(context)
  context.response.close
  scope.exit

  HTTP::Client::Response.from_io(IO::Memory.new(io.to_s))
end

describe LF::Security do
  it "reuses guards to distinguish anonymous and unauthorized API requests" do
    principal = LF::Security::Principal.new("api-user", ["projects:read"])
    authenticator = LF::Security::APIKeyAuthenticator.new({"secret-api-key" => principal})
    handler, root = security_spec_app(authenticator)

    anonymous = call_security_spec_app(handler, root, "/secured")
    anonymous.status.should eq(HTTP::Status::UNAUTHORIZED)

    invalid = call_security_spec_app(
      handler,
      root,
      "/secured",
      headers: HTTP::Headers{"Authorization" => "ApiKey wrong"}
    )
    invalid.status.should eq(HTTP::Status::UNAUTHORIZED)
    invalid.headers["WWW-Authenticate"].should eq("Bearer")

    authenticated = call_security_spec_app(
      handler,
      root,
      "/secured",
      headers: HTTP::Headers{"Authorization" => "ApiKey secret-api-key"}
    )
    authenticated.status.should eq(HTTP::Status::OK)
    authenticated.body.should eq("secured")
    root.shutdown
  end

  it "returns forbidden when an authenticated principal lacks an authority" do
    principal = LF::Security::Principal.new("api-user")
    authenticator = LF::Security::APIKeyAuthenticator.new({"secret-api-key" => principal})
    handler, root = security_spec_app(authenticator)

    response = call_security_spec_app(
      handler,
      root,
      "/authority",
      headers: HTTP::Headers{"Authorization" => "ApiKey secret-api-key"}
    )

    response.status.should eq(HTTP::Status::FORBIDDEN)
    root.shutdown
  end

  it "signs cookie sessions and applies CSRF through the existing interceptor" do
    session = LF::Security::SignedSession.new("s" * 32)
    issued = session.issue(LF::Security::Principal.new("browser-user"))
    handler, root = security_spec_app(session)
    cookie_headers = HTTP::Headers{"Cookie" => issued.cookie.to_cookie_header}

    rejected = call_security_spec_app(handler, root, "/session", "POST", cookie_headers)
    rejected.status.should eq(HTTP::Status::FORBIDDEN)

    accepted_headers = cookie_headers.dup
    accepted_headers["X-CSRF-Token"] = issued.csrf_token
    accepted = call_security_spec_app(handler, root, "/session", "POST", accepted_headers)
    accepted.status.should eq(HTTP::Status::OK)
    accepted.body.should eq("changed")
    root.shutdown
  end
end
