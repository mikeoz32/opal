require "./spec_helper"
require "../src/opal"
require "http/client"

class WebSocketSyncSpecController
  include LF::HTTP::Controller

  @[LF::HTTP::Controller::WebSocket("/sync-ws")]
  def echo(ws : HTTP::WebSocket) : Nil
    message = ws.receive
    ws.send("sync:#{message}")
    ws.close
  end
end

describe "synchronous websocket controller actions" do
  it "can receive and respond directly in the action body" do
    root = LF::DI::DefaultContainer.new
    app = LF::HTTP::App.new do |router|
      WebSocketSyncSpecController.setup_routes(router, root)
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

    protocol = HTTP::WebSocket::Protocol.new("127.0.0.1", "/sync-ws", address.port)
    websocket = HTTP::WebSocket.new(protocol)
    websocket.send("hello")
    response = Channel(String | Bytes).new(1)
    spawn do
      response.send(websocket.receive)
    rescue
      response.send("receive failed")
    end
    select
    when message = response.receive
      message.as(String).should eq("sync:hello")
    when timeout(2.seconds)
      fail "synchronous websocket response was not received"
    end

    closed = Channel(Bool).new(1)
    spawn do
      closed.send(websocket.receive?.nil?)
    rescue
      closed.send(false)
    end
    select
    when result = closed.receive
      result.should be_true
    when timeout(2.seconds)
      fail "synchronous websocket did not close"
    end
  ensure
    websocket.try(&.close)
    server.try(&.close)
    root.try(&.shutdown)
  end
end
