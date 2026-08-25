require "./spec_helper"
require "../src/opal"
require "../src/opal/autoconfig/http"
require "http/client"

class HTTPAutoConfigSpecController
  include LF::HTTP::Controller

  @[LF::HTTP::Controller::Get("/autoconfig")]
  def show : String
    "discovered"
  end
end

class HTTPAutoConfigDrainProbe
  include LF::DI::Disposable

  @@destroyed = false

  def self.reset : Nil
    @@destroyed = false
  end

  def self.destroyed? : Bool
    @@destroyed
  end

  def destroy : Nil
    @@destroyed = true
  end
end

class HTTPAutoConfigRequestProbe
  include LF::DI::Disposable

  getter? destroyed = false

  def destroy : Nil
    @destroyed = true
  end
end

class HTTPAutoConfigDrainController
  include LF::HTTP::Controller

  @@started = Channel(Nil).new
  @@release = Channel(Nil).new

  def self.reset : Nil
    @@started = Channel(Nil).new
    @@release = Channel(Nil).new
  end

  def self.wait_until_started : Nil
    @@started.receive
  end

  def self.release : Nil
    @@release.send(nil)
  end

  def initialize(@http_auto_config_drain_probe : HTTPAutoConfigDrainProbe)
  end

  @[LF::HTTP::Controller::Get("/autoconfig/drain")]
  def show : String
    @@started.send(nil)
    @@release.receive
    raise "singleton destroyed during request" if HTTPAutoConfigDrainProbe.destroyed?
    "drained"
  end
end

class HTTPAutoConfigUpgradeBlocker
  getter upgraded = Channel(Nil).new(1)
  getter release = Channel(Nil).new
  getter probe : HTTPAutoConfigRequestProbe?

  def call(context : HTTP::Server::Context) : Nil
    scope = context.dependency_scope.not_nil!.as(LF::DI::Container)
    @probe = probe = scope.resolve("http_auto_config_request_probe", HTTPAutoConfigRequestProbe)
    context.response.status = HTTP::Status::SWITCHING_PROTOCOLS
    context.response.headers["Connection"] = "Upgrade"
    context.response.headers["Upgrade"] = "opal-test"
    context.response.upgrade do |_io|
      raise "request scope destroyed before upgrade work" if probe.destroyed?
      @upgraded.send(nil)
      @release.receive
      raise "request scope destroyed during upgrade work" if probe.destroyed?
    end
  end
end

class HTTPAutoConfigBlockingCloseOutput < IO
  @closed = false

  def initialize(
    @output : IO,
    @closing : Channel(Nil),
    @release : Channel(Nil),
    @probe : HTTPAutoConfigRequestProbe,
  )
  end

  def read(slice : Bytes) : NoReturn
    raise IO::Error.new("response output is write-only")
  end

  def write(slice : Bytes) : Nil
    @output.write(slice)
  end

  def flush : Nil
    @output.flush
  end

  def close : Nil
    return if @closed
    raise "request scope destroyed before output finalization" if @probe.destroyed?
    @closing.send(nil)
    @release.receive
    raise "request scope destroyed during output finalization" if @probe.destroyed?
    @output.close
  ensure
    @closed = true
  end

  def closed? : Bool
    @closed
  end
end

class HTTPAutoConfigOutputFinalizer
  getter closing = Channel(Nil).new(1)
  getter release = Channel(Nil).new
  getter probe : HTTPAutoConfigRequestProbe?

  def call(context : HTTP::Server::Context) : Nil
    scope = context.dependency_scope.not_nil!.as(LF::DI::Container)
    @probe = probe = scope.resolve("http_auto_config_request_probe", HTTPAutoConfigRequestProbe)
    context.response.output = HTTPAutoConfigBlockingCloseOutput.new(
      context.response.output,
      @closing,
      @release,
      probe
    )
    context.response.print "finalized"
  end
end

class HTTPAutoConfigWebSocketController
  @@connected = Channel(Nil).new

  def self.reset : Nil
    @@connected = Channel(Nil).new
  end

  def self.wait_until_connected : Nil
    select
    when @@connected.receive
    when timeout(5.seconds)
      fail "websocket controller did not connect"
    end
  end

  include LF::HTTP::Controller

  @[LF::HTTP::Controller::WebSocket("/autoconfig/ws")]
  def connect(ws : HTTP::WebSocket) : Nil
    @@connected.send(nil)
  end
end

private def with_http_config(contents : String, &block : String ->)
  path = "/tmp/opal-http-autoconfig-#{Process.pid}-#{Random.rand(1_000_000)}.yml"
  File.write(path, contents)
  yield path
ensure
  File.delete(path) if path && File.exists?(path)
end

private def build_http_runtime(path : String, *, request_probe : Bool = false) : LF::ApplicationRuntime
  root = LF::DI::DefaultContainer.new
  root.add_bean(name: "config_service", type: LF::ConfigService) do |_scope|
    LF::ConfigService.new(path)
  end
  if request_probe
    root.add_bean(
      name: "http_auto_config_request_probe",
      scope: "request",
      type: HTTPAutoConfigRequestProbe
    ) do |_scope|
      HTTPAutoConfigRequestProbe.new
    end
  end
  root.resolve(LF::ConfigService)
  LF::ApplicationRuntime.new(root)
end

describe LF::HTTP::AutoConfig do
  it "discovers controllers, binds configured host, and supports port zero" do
    with_http_config("http:\n  host: 127.0.0.1\n  port: 0\n") do |path|
      runtime = build_http_runtime(path)
      extension = LF::HTTP::AutoConfig.install(runtime)
      address = extension.bind
      address.address.should eq("127.0.0.1")
      address.port.should be > 0

      listening = Channel(Nil).new
      spawn do
        listening.send(nil)
        extension.listen
      end
      listening.receive
      Fiber.yield

      response = HTTP::Client.get("http://127.0.0.1:#{address.port}/autoconfig")
      response.status.should eq(HTTP::Status::OK)
      response.body.should eq("discovered")

      runtime.shutdown
      extension.stopped?.should be_true
    end
  end

  it "uses the documented host and port defaults" do
    with_http_config("{}\n") do |path|
      runtime = build_http_runtime(path)
      extension = LF::HTTP::AutoConfig.install(runtime)

      extension.configured_host.should eq("0.0.0.0")
      extension.configured_port.should eq(8080)
      extension.configured_drain_timeout.should eq(30.seconds)
      extension.websocket_shutdown_timeout_ms.should eq(5000)

      runtime.shutdown
    end
  end

  it "uses the configured websocket shutdown timeout" do
    with_http_config("http:\n  websocket:\n    shutdown_timeout_ms: 125\n") do |path|
      runtime = build_http_runtime(path)
      extension = LF::HTTP::AutoConfig.install(runtime)

      extension.websocket_shutdown_timeout_ms.should eq(125)

      runtime.shutdown
    end
  end

  it "sends Going Away to active websocket connections during stop" do
    HTTPAutoConfigWebSocketController.reset

    with_http_config("http:\n  host: 127.0.0.1\n  port: 0\n  websocket:\n    shutdown_timeout_ms: 100\n") do |path|
      runtime = build_http_runtime(path)
      extension = LF::HTTP::AutoConfig.install(runtime)
      address = extension.bind
      spawn { extension.listen }

      protocol = HTTP::WebSocket::Protocol.new("127.0.0.1", "/autoconfig/ws", address.port)
      websocket = HTTP::WebSocket.new(protocol)
      HTTPAutoConfigWebSocketController.wait_until_connected

      closed = Channel(HTTP::WebSocket::CloseCode).new(1)
      websocket.on_close { |code, _message| closed.send(code) }
      spawn { websocket.receive? rescue nil }

      extension.stop

      select
      when code = closed.receive
        code.should eq(HTTP::WebSocket::CloseCode::GoingAway)
      when timeout(2.seconds)
        fail "websocket was not closed during extension stop"
      end
      runtime.shutdown
    ensure
      websocket.try(&.close)
    end
  end

  it "raises a typed error for invalid HTTP configuration" do
    with_http_config("http:\n  port: invalid\n") do |path|
      runtime = build_http_runtime(path)

      expect_raises(LF::HTTP::AutoConfig::ConfigurationError, "Invalid HTTP configuration") do
        LF::HTTP::AutoConfig.install(runtime)
      end

      runtime.closed?.should be_true
    end
  end

  it "rejects a non-positive drain timeout" do
    with_http_config("http:\n  drain_timeout_ms: 0\n") do |path|
      runtime = build_http_runtime(path)

      expect_raises(
        LF::HTTP::AutoConfig::ConfigurationError,
        "http.drain_timeout_ms must be positive"
      ) do
        LF::HTTP::AutoConfig.install(runtime)
      end

      runtime.closed?.should be_true
    end
  end

  it "stops idempotently" do
    with_http_config("http:\n  host: 127.0.0.1\n  port: 0\n") do |path|
      runtime = build_http_runtime(path)
      extension = LF::HTTP::AutoConfig.install(runtime)

      extension.stop
      extension.stop
      extension.stopped?.should be_true

      runtime.shutdown
    end
  end

  it "waits for active request scopes before root DI shutdown" do
    HTTPAutoConfigDrainProbe.reset
    HTTPAutoConfigDrainController.reset

    with_http_config("http:\n  host: 127.0.0.1\n  port: 0\n") do |path|
      root = LF::DI::DefaultContainer.new
      root.add_bean(name: "config_service", type: LF::ConfigService) do |_scope|
        LF::ConfigService.new(path)
      end
      root.add_bean(name: "http_auto_config_drain_probe", type: HTTPAutoConfigDrainProbe) do |_scope|
        HTTPAutoConfigDrainProbe.new
      end
      root.resolve(LF::ConfigService)
      runtime = LF::ApplicationRuntime.new(root)
      extension = LF::HTTP::AutoConfig.install(runtime)
      address = extension.bind

      spawn { extension.listen }
      response = Channel(HTTP::Client::Response).new
      spawn do
        response.send(HTTP::Client.get("http://127.0.0.1:#{address.port}/autoconfig/drain"))
      end
      HTTPAutoConfigDrainController.wait_until_started

      shutdown = Channel(Exception?).new
      spawn do
        begin
          runtime.shutdown
          shutdown.send(nil)
        rescue error : Exception
          shutdown.send(error)
        end
      end
      sleep 10.milliseconds
      destroyed_early = HTTPAutoConfigDrainProbe.destroyed?

      HTTPAutoConfigDrainController.release
      response.receive.body.should eq("drained")
      shutdown.receive.should be_nil
      destroyed_early.should be_false
      HTTPAutoConfigDrainProbe.destroyed?.should be_true
    end
  end

  it "closes idle keep-alive connections during drain" do
    with_http_config("http:\n  host: 127.0.0.1\n  port: 0\n  drain_timeout_ms: 100\n") do |path|
      runtime = build_http_runtime(path)
      extension = LF::HTTP::AutoConfig.install(runtime)
      address = extension.bind
      spawn { extension.listen }
      client = HTTP::Client.new(address.address, address.port)

      client.get("/autoconfig").status.should eq(HTTP::Status::OK)
      runtime.shutdown

      expect_raises(IO::Error) { client.get("/autoconfig") }
      client.close
    end
  end

  it "waits for upgraded connection work after the route handler returns" do
    with_http_config("http:\n  host: 127.0.0.1\n  port: 0\n  drain_timeout_ms: 2000\n") do |path|
      runtime = build_http_runtime(path, request_probe: true)
      blocker = HTTPAutoConfigUpgradeBlocker.new
      extension = runtime.install(
        LF::HTTP::AutoConfig::Extension.new do |_context|
          LF::HTTP::App.new do |router|
            router.get("/upgrade") { |request_context, _params| blocker.call(request_context) }
          end
        end
      )
      address = extension.bind
      spawn { extension.listen }
      socket = TCPSocket.new(address.address, address.port)
      socket << "GET /upgrade HTTP/1.1\r\nHost: test\r\nConnection: Upgrade\r\nUpgrade: opal-test\r\n\r\n"
      socket.flush
      blocker.upgraded.receive

      shutdown = Channel(Exception?).new(1)
      spawn do
        begin
          runtime.shutdown
          shutdown.send(nil)
        rescue error : Exception
          shutdown.send(error)
        end
      end
      Fiber.yield
      select
      when early = shutdown.receive
        raise "shutdown returned before upgraded work drained: #{early}"
      else
      end

      blocker.release.send(nil)
      shutdown.receive.should be_nil
      blocker.probe.not_nil!.destroyed?.should be_true
      socket.close
    end
  end

  it "waits for response output finalization after the route handler returns" do
    with_http_config("http:\n  host: 127.0.0.1\n  port: 0\n  drain_timeout_ms: 2000\n") do |path|
      runtime = build_http_runtime(path, request_probe: true)
      finalizer = HTTPAutoConfigOutputFinalizer.new
      extension = runtime.install(
        LF::HTTP::AutoConfig::Extension.new do |_context|
          LF::HTTP::App.new do |router|
            router.get("/finalize") { |request_context, _params| finalizer.call(request_context) }
          end
        end
      )
      address = extension.bind
      spawn { extension.listen }
      response = Channel(HTTP::Client::Response | Exception).new(1)
      spawn do
        begin
          response.send(HTTP::Client.get("http://#{address.address}:#{address.port}/finalize"))
        rescue error : Exception
          response.send(error)
        end
      end
      finalizer.closing.receive

      shutdown = Channel(Exception?).new(1)
      spawn do
        begin
          runtime.shutdown
          shutdown.send(nil)
        rescue error : Exception
          shutdown.send(error)
        end
      end
      Fiber.yield
      select
      when early = shutdown.receive
        raise "shutdown returned before response output finalized: #{early}"
      else
      end

      finalizer.release.send(nil)
      result = response.receive
      result.should be_a(HTTP::Client::Response)
      result.as(HTTP::Client::Response).body.should eq("finalized")
      shutdown.receive.should be_nil
      finalizer.probe.not_nil!.destroyed?.should be_true
    end
  end

  it "retains root DI after a drain deadline until the request scope exits" do
    HTTPAutoConfigDrainProbe.reset
    HTTPAutoConfigDrainController.reset

    with_http_config("http:\n  host: 127.0.0.1\n  port: 0\n  drain_timeout_ms: 20\n") do |path|
      root = LF::DI::DefaultContainer.new
      root.add_bean(name: "config_service", type: LF::ConfigService) do |_scope|
        LF::ConfigService.new(path)
      end
      root.add_bean(name: "http_auto_config_drain_probe", type: HTTPAutoConfigDrainProbe) do |_scope|
        HTTPAutoConfigDrainProbe.new
      end
      root.resolve(LF::ConfigService)
      runtime = LF::ApplicationRuntime.new(root)
      extension = LF::HTTP::AutoConfig.install(runtime)
      address = extension.bind
      spawn { extension.listen }
      response = Channel(HTTP::Client::Response | Exception).new(1)
      spawn do
        begin
          response.send(HTTP::Client.get("http://#{address.address}:#{address.port}/autoconfig/drain"))
        rescue error : Exception
          response.send(error)
        end
      end
      HTTPAutoConfigDrainController.wait_until_started

      error = expect_raises(LF::ApplicationRuntime::ShutdownError) { runtime.shutdown }
      drain_error = error.extension_errors.first.as(LF::HTTP::AutoConfig::DrainTimeoutError)
      drain_error.active_requests.should eq(1)
      runtime.shutdown_pending?.should be_true
      runtime.closed?.should be_false
      HTTPAutoConfigDrainProbe.destroyed?.should be_false
      repeated = expect_raises(LF::HTTP::AutoConfig::DrainTimeoutError) { extension.stop }
      repeated.active_requests.should eq(1)

      HTTPAutoConfigDrainController.release
      response.receive.should be_a(Exception)
      runtime.shutdown

      runtime.closed?.should be_true
      HTTPAutoConfigDrainProbe.destroyed?.should be_true
    end
  end
end
