require "./spec_helper"
require "http/client"
require "../src/opal"
require "../src/opal/autoconfig/http"
require "../src/opal/security"

@[LF::HTTP::UseGuards(LF::Security::AuthenticatedGuard)]
class SecurityAutoConfigSpecController
  include LF::HTTP::Controller

  def initialize(@security_context : LF::Security::Context)
  end

  @[LF::HTTP::Controller::Get("/security-autoconfig")]
  def index : String
    "secured by #{@security_context.principal.subject}"
  end

  @[LF::HTTP::Controller::WebSocket("/security-autoconfig/ws")]
  def websocket(ws : HTTP::WebSocket) : Nil
    ws.on_message { |message| ws.send("secured:#{message}") }
  end
end

describe "security autoconfiguration" do
  it "adds authentication between the request scope and controller router" do
    config_path = File.join(__DIR__, "fixtures/security/application.yml")
    root = LF::DI::DefaultContainer.new
    root.register(LF::DI::ServiceConfiguration.new)
    root.add_bean(name: "config_service", type: LF::ConfigService) do |_scope|
      LF::ConfigService.new(config_path)
    end
    root.add_bean(
      name: "security_authenticator",
      type: LF::Security::Authenticator
    ) do |_scope|
      LF::Security::APIKeyAuthenticator.new({
        "security-autoconfig-key" => LF::Security::Principal.new("autoconfig-user"),
      }).as(LF::Security::Authenticator)
    end
    runtime = LF::ApplicationRuntime.new(root)
    runtime.install(LF::Security::AutoConfig::Extension.new)
    extension = LF::HTTP::AutoConfig.install(runtime)
    address = extension.bind
    spawn { extension.listen }
    Fiber.yield

    anonymous = HTTP::Client.get("http://#{address.address}:#{address.port}/security-autoconfig")
    anonymous.status.should eq(HTTP::Status::UNAUTHORIZED)

    authenticated = HTTP::Client.get(
      "http://#{address.address}:#{address.port}/security-autoconfig",
      headers: HTTP::Headers{"Authorization" => "ApiKey security-autoconfig-key"}
    )
    authenticated.status.should eq(HTTP::Status::OK)
    authenticated.body.should eq("secured by autoconfig-user")

    denied_upgrade = HTTP::Client.get(
      "http://#{address.address}:#{address.port}/security-autoconfig/ws",
      headers: HTTP::Headers{
        "Connection" => "Upgrade",
        "Upgrade"    => "websocket",
      }
    )
    denied_upgrade.status.should eq(HTTP::Status::UNAUTHORIZED)

    protocol = HTTP::WebSocket::Protocol.new(
      address.address,
      "/security-autoconfig/ws",
      address.port,
      nil,
      HTTP::Headers{"Authorization" => "ApiKey security-autoconfig-key"},
    )
    websocket = HTTP::WebSocket.new(protocol)
    websocket.send("hello")
    websocket.receive.should eq("secured:hello")
    websocket.close
  ensure
    websocket.try(&.close)
    runtime.try(&.shutdown) unless runtime.try(&.closed?)
  end
end
