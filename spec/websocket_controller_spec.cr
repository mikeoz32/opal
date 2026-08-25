require "./spec_helper"
require "../src/opal"
require "http/client"

class WebSocketControllerSpecService
  getter value : String

  def initialize(@value : String)
  end
end

class WebSocketControllerSpecController
  include LF::HTTP::Controller
  include LF::DI::Disposable

  @@destroyed = Channel(Nil).new

  def self.reset : Nil
    @@destroyed = Channel(Nil).new
  end

  def self.wait_destroyed : Nil
    select
    when @@destroyed.receive
    when timeout(5.seconds)
      fail "websocket controller was not destroyed"
    end
  end

  def initialize(@websocket_controller_spec_service : WebSocketControllerSpecService)
  end

  @[LF::HTTP::Controller::WebSocket("/controller-ws/:id", protocols: ["controller.v1"])]
  def echo(ws : HTTP::WebSocket, id : Int32, request : HTTP::Request) : Nil
    test_header = request.headers["X-Test"]?
    ws.on_message do |message|
      ws.send("#{@websocket_controller_spec_service.value}:#{id}:#{request.path}:#{test_header}:#{message}")
    end
  end

  def destroy : Nil
    @@destroyed.send(nil)
  end
end

describe LF::HTTP::Controller do
  it "discovers websocket actions, binds arguments, and uses a websocket DI scope" do
    WebSocketControllerSpecController.reset
    root = LF::DI::DefaultContainer.new
    root.add_bean(name: "websocket_controller_spec_service", type: WebSocketControllerSpecService) do |_scope|
      WebSocketControllerSpecService.new("injected")
    end

    app = LF::HTTP::App.new do |router|
      WebSocketControllerSpecController.setup_routes(router, root)
    end
    server = HTTP::Server.new([
      LF::HTTP::DI::WebSocketScopeHandler.new(root),
      LF::HTTP::DI::RequestScopeHandler.new(root),
      app,
    ])
    address = server.bind_tcp("127.0.0.1", 0)
    listening = Channel(Nil).new
    spawn do
      listening.send(nil)
      server.listen
    end
    listening.receive
    Fiber.yield

    headers = HTTP::Headers{"X-Test" => "yes"}
    protocol = HTTP::WebSocket::Protocol.new(
      "127.0.0.1",
      "/controller-ws/7",
      address.port,
      nil,
      headers,
      ["controller.v1"]
    )
    websocket = HTTP::WebSocket.new(protocol)
    protocol.protocol.should eq("controller.v1")

    websocket.send("hello")
    websocket.receive.should eq("injected:7:/controller-ws/7:yes:hello")
    websocket.close
    WebSocketControllerSpecController.wait_destroyed
  ensure
    websocket.try(&.close)
    server.try(&.close)
    root.try(&.shutdown)
  end
end
