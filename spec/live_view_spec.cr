require "./spec_helper"
require "../src/opal"
require "http/client"

class LiveViewSpecCounter < LF::LiveView::View
  @count = 0
  @connected = false

  def mount(context : LF::LiveView::MountContext) : Nil
    @connected = context.connected?
  end

  def render : String
    connected = @connected ? "yes" : "no"
    %(<button data-opal-click="increment">#{@count}</button><span>#{connected}</span>)
  end

  def handle_event(event : String, value : JSON::Any) : Nil
    case event
    when "increment"
      @count += 1
    else
      super
    end
  end

  def title : String?
    "Counter #{@count}"
  end
end

class LiveViewSpecForbidden < LF::LiveView::View
  def mount(context : LF::LiveView::MountContext) : Nil
    raise LF::HTTP::Forbidden.new if context.connected?
  end

  def render : String
    "initially allowed"
  end
end

class LiveViewSpecPush < LF::LiveView::View
  @@mounted = Channel(LiveViewSpecPush).new(1)

  def self.reset : Nil
    @@mounted = Channel(LiveViewSpecPush).new(1)
  end

  def self.wait_until_mounted : LiveViewSpecPush
    @@mounted.receive
  end

  @value = 0

  def mount(context : LF::LiveView::MountContext) : Nil
    @@mounted.send(self) if context.connected?
  end

  def push(value : Int32) : Nil
    @value = value
    refresh
  end

  def render : String
    %(<output>#{@value}</output>)
  end
end

private def live_view_spec_server(secret : String, &block : Socket::IPAddress ->)
  LiveViewSpecPush.reset
  root = LF::DI::DefaultContainer.new
  endpoint = LF::LiveView::Endpoint.new(secret)
  endpoint.page("/counter", LiveViewSpecCounter) { |_scope| LiveViewSpecCounter.new }
  endpoint.page("/forbidden", LiveViewSpecForbidden) { |_scope| LiveViewSpecForbidden.new }
  endpoint.page("/push", LiveViewSpecPush) { |_scope| LiveViewSpecPush.new }
  app = LF::HTTP::App.new do |router|
    endpoint.mount(router)
  end
  server = HTTP::Server.new([
    LF::HTTP::DI::WebSocketScopeHandler.new(root),
    LF::HTTP::DI::RequestScopeHandler.new(root),
    app,
  ])
  address = server.bind_tcp("127.0.0.1", 0)
  spawn { server.listen }
  Fiber.yield
  yield address
ensure
  server.try(&.close)
  root.try(&.shutdown)
end

describe LF::LiveView do
  it "escapes HTML text and attributes" do
    LF::LiveView::HTML.escape(%(<Mike & "Opal">)).should eq("&lt;Mike &amp; &quot;Opal&quot;&gt;")
  end

  it "signs mount state and rejects tampering and expired tokens" do
    tokens = LF::LiveView::MountToken.new("s" * 32, 1.hour)
    token = tokens.sign("Counter", {"id" => "7"}, "/counter?id=7")

    mount = tokens.verify(token)
    mount.route.should eq("Counter")
    mount.params.should eq({"id" => "7"})
    mount.resource.should eq("/counter?id=7")

    expect_raises(LF::LiveView::InvalidMountTokenError) do
      tokens.verify(token.sub('C', 'X'))
    end
    expect_raises(LF::LiveView::InvalidMountTokenError) do
      tokens.verify(token, Time.utc + 2.hours)
    end
  end

  it "requires a strong mount-token secret" do
    expect_raises(LF::LiveView::ConfigurationError, "at least 32 bytes") do
      LF::LiveView::MountToken.new("short")
    end
  end

  it "rejects page paths that collide with an existing GET route" do
    endpoint = LF::LiveView::Endpoint.new("h" * 32)
    endpoint.page("/counter", LiveViewSpecCounter) { |_scope| LiveViewSpecCounter.new }
    router = LF::HTTP::Router.new
    router.get("//counter/") { |_context, _params| }

    expect_raises(LF::LiveView::ConfigurationError, "conflicts with an existing route") do
      endpoint.mount(router)
    end
  end

  it "renders over HTTP and serves its dependency-free browser client" do
    live_view_spec_server("a" * 32) do |address|
      response = HTTP::Client.get("http://#{address.address}:#{address.port}/counter?source=spec")
      response.status.should eq(HTTP::Status::OK)
      response.headers["Content-Type"].should eq("text/html; charset=utf-8")
      response.body.should contain("data-opal-live-root")
      response.body.should contain(%(<span>no</span>))
      response.body.should contain(%(<script type="module" src="/_opal/live.js">))

      client = HTTP::Client.get("http://#{address.address}:#{address.port}/_opal/live.js")
      client.status.should eq(HTTP::Status::OK)
      client.body.should contain("export class OpalLiveView")
      client.body.should_not contain("phoenix")
    end
  end

  it "mounts connected state, handles ordered events, and answers heartbeats" do
    live_view_spec_server("b" * 32) do |address|
      response = HTTP::Client.get("http://#{address.address}:#{address.port}/counter")
      token = response.body.match(/data-opal-token="([^"]+)"/).not_nil![1]
      headers = HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}
      websocket = HTTP::WebSocket.new(
        "127.0.0.1",
        "/_opal/live",
        port: address.port,
        headers: headers
      )

      websocket.send({type: "join", protocol: 1, token: token}.to_json)
      joined = JSON.parse(websocket.receive.as(String))
      joined["type"].as_s.should eq("render")
      joined["protocol"].as_i64.should eq(1)
      joined["version"].as_i64.should eq(0)
      joined["html"].as_s.should contain(%(<span>yes</span>))

      websocket.send({
        type:    "event",
        event:   "increment",
        value:   {source: "spec"},
        version: 0,
      }.to_json)
      rendered = JSON.parse(websocket.receive.as(String))
      rendered["version"].as_i64.should eq(1)
      rendered["html"].as_s.should contain(">1</button>")
      rendered["title"].as_s.should eq("Counter 1")

      websocket.send({type: "heartbeat", ref: 9}.to_json)
      heartbeat = JSON.parse(websocket.receive.as(String))
      heartbeat["type"].as_s.should eq("heartbeat")
      heartbeat["ref"].as_i64.should eq(9)
      websocket.close
    ensure
      websocket.try(&.close)
    end
  end

  it "resynchronizes stale events without applying them" do
    live_view_spec_server("c" * 32) do |address|
      response = HTTP::Client.get("http://#{address.address}:#{address.port}/counter")
      token = response.body.match(/data-opal-token="([^"]+)"/).not_nil![1]
      websocket = HTTP::WebSocket.new(
        "127.0.0.1",
        "/_opal/live",
        port: address.port,
        headers: HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}
      )
      websocket.send({type: "join", protocol: 1, token: token}.to_json)
      websocket.receive

      websocket.send({type: "event", event: "increment", value: nil, version: 42}.to_json)
      rendered = JSON.parse(websocket.receive.as(String))
      rendered["version"].as_i64.should eq(0)
      rendered["html"].as_s.should contain(">0</button>")
      websocket.close
    ensure
      websocket.try(&.close)
    end
  end

  it "serializes server-initiated refreshes on the connection" do
    live_view_spec_server("g" * 32) do |address|
      response = HTTP::Client.get("http://#{address.address}:#{address.port}/push")
      token = response.body.match(/data-opal-token="([^"]+)"/).not_nil![1]
      websocket = HTTP::WebSocket.new(
        "127.0.0.1",
        "/_opal/live",
        port: address.port,
        headers: HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}
      )
      websocket.send({type: "join", protocol: 1, token: token}.to_json)
      initial = JSON.parse(websocket.receive.as(String))
      initial["version"].as_i64.should eq(0)

      LiveViewSpecPush.wait_until_mounted.push(7)

      pushed = JSON.parse(websocket.receive.as(String))
      pushed["version"].as_i64.should eq(1)
      pushed["html"].as_s.should contain(">7</output>")
      websocket.close
    ensure
      websocket.try(&.close)
    end
  end

  it "rejects an unsupported protocol version" do
    live_view_spec_server("e" * 32) do |address|
      response = HTTP::Client.get("http://#{address.address}:#{address.port}/counter")
      token = response.body.match(/data-opal-token="([^"]+)"/).not_nil![1]
      websocket = HTTP::WebSocket.new(
        "127.0.0.1",
        "/_opal/live",
        port: address.port,
        headers: HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}
      )
      close = Channel(HTTP::WebSocket::CloseCode).new(1)
      websocket.on_close { |code, _reason| close.send(code) }

      websocket.send({type: "join", protocol: 2, token: token}.to_json)
      websocket.receive?.should be_nil
      close.receive.should eq(HTTP::WebSocket::CloseCode::ProtocolError)
    ensure
      websocket.try(&.close)
    end
  end

  it "maps connected-mount authorization failures to policy violation" do
    live_view_spec_server("f" * 32) do |address|
      response = HTTP::Client.get("http://#{address.address}:#{address.port}/forbidden")
      token = response.body.match(/data-opal-token="([^"]+)"/).not_nil![1]
      websocket = HTTP::WebSocket.new(
        "127.0.0.1",
        "/_opal/live",
        port: address.port,
        headers: HTTP::Headers{"Origin" => "http://#{address.address}:#{address.port}"}
      )
      close = Channel(HTTP::WebSocket::CloseCode).new(1)
      websocket.on_close { |code, _reason| close.send(code) }

      websocket.send({type: "join", protocol: 1, token: token}.to_json)
      websocket.receive?.should be_nil
      close.receive.should eq(HTTP::WebSocket::CloseCode::PolicyViolation)
    ensure
      websocket.try(&.close)
    end
  end

  it "rejects a cross-origin handshake before upgrading" do
    live_view_spec_server("d" * 32) do |address|
      headers = HTTP::Headers{
        "Connection" => "Upgrade",
        "Upgrade"    => "websocket",
        "Origin"     => "https://evil.example",
      }
      response = HTTP::Client.get(
        "http://#{address.address}:#{address.port}/_opal/live",
        headers: headers
      )

      response.status.should eq(HTTP::Status::FORBIDDEN)
    end
  end
end
