require "./spec_helper"
require "../src/opal"

class WebSocketFailureSpecController
  include LF::HTTP::Controller

  @[LF::HTTP::Controller::WebSocket("/controller-ws-failure")]
  def fail_setup(ws : HTTP::WebSocket) : Nil
    raise "private setup detail"
  end
end

describe "native websocket transport" do
  it "delivers binary messages without converting them to text" do
    app = LF::HTTP::App.new do |router|
      router.ws("/binary") do |websocket, _params|
        websocket.on_binary { |message| websocket.send(message) }
      end
    end
    server = HTTP::Server.new(app)
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    Fiber.yield
    websocket = HTTP::WebSocket.new("127.0.0.1", "/binary", port: address.port)

    websocket.send(Bytes[0_u8, 1_u8, 255_u8])

    websocket.receive.should eq(Bytes[0_u8, 1_u8, 255_u8])
    websocket.close
  ensure
    websocket.try(&.close)
    server.try(&.close)
  end

  it "closes controller setup failures with a safe 1011 response" do
    root = LF::DI::DefaultContainer.new
    app = LF::HTTP::App.new do |router|
      WebSocketFailureSpecController.setup_routes(router, root)
    end
    server = HTTP::Server.new([
      LF::HTTP::DI::WebSocketScopeHandler.new(root),
      LF::HTTP::DI::RequestScopeHandler.new(root),
      app,
    ])
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    Fiber.yield
    websocket = HTTP::WebSocket.new(
      "127.0.0.1",
      "/controller-ws-failure",
      port: address.port
    )
    close = Channel({HTTP::WebSocket::CloseCode, String}).new(1)
    websocket.on_close { |code, reason| close.send({code, reason}) }

    websocket.receive?.should be_nil
    code, reason = close.receive

    code.should eq(HTTP::WebSocket::CloseCode::InternalServerError)
    reason.should be_empty
    reason.should_not contain("private setup detail")
  ensure
    websocket.try(&.close)
    server.try(&.close)
    root.try(&.shutdown)
  end
end
