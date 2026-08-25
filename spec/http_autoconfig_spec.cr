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

private def with_http_config(contents : String, &block : String ->)
  path = "/tmp/opal-http-autoconfig-#{Process.pid}-#{Random.rand(1_000_000)}.yml"
  File.write(path, contents)
  yield path
ensure
  File.delete(path) if path && File.exists?(path)
end

private def build_http_runtime(path : String) : LF::ApplicationRuntime
  root = LF::DI::DefaultContainer.new
  root.add_bean(name: "config_service", type: LF::ConfigService) do |_scope|
    LF::ConfigService.new(path)
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

      runtime.shutdown
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
end
