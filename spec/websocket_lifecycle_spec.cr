require "./spec_helper"
require "../src/opal"

describe LF::HTTP::WebSocketConnectionRegistry do
  it "tracks connections until the upgrade handler exits" do
    registry = LF::HTTP::WebSocketConnectionRegistry.new
    io = IO::Memory.new
    websocket = HTTP::WebSocket.new(HTTP::WebSocket::Protocol.new(io, sync_close: false))
    connection = registry.register(websocket, io)

    registry.size.should eq(1)
    registry.unregister(connection)
    registry.size.should eq(0)
  end

  it "sends Going Away and force-closes connections after the timeout" do
    registry = LF::HTTP::WebSocketConnectionRegistry.new
    io = IO::Memory.new
    websocket = HTTP::WebSocket.new(HTTP::WebSocket::Protocol.new(io, sync_close: false))
    registry.register(websocket, io)

    registry.shutdown(1)

    io.closed?.should be_true
    io.to_slice[0, 2].should eq(Bytes[0x88, 0x02])
  end

  it "uses one timeout budget for graceful close and force-close" do
    registry = LF::HTTP::WebSocketConnectionRegistry.new
    io = IO::Memory.new
    websocket = HTTP::WebSocket.new(HTTP::WebSocket::Protocol.new(io, sync_close: false))
    registry.register(websocket, io)
    started = Time.instant

    registry.shutdown(10)

    (Time.instant - started).should be < 100.milliseconds
  end
end
