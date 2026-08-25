require "./spec_helper"
require "../src/opal"

class ApplicationSpecValue
  getter value : String

  def initialize(@value : String)
  end
end

class ApplicationSpecConfigConsumer
  getter config : LF::ConfigService

  def initialize(@config : LF::ConfigService)
  end
end

class ApplicationSpecShutdownProbe
  include LF::DI::Disposable

  @@destroy_calls = 0

  def self.destroy_calls : Int32
    @@destroy_calls
  end

  def self.reset : Nil
    @@destroy_calls = 0
  end

  def destroy : Nil
    @@destroy_calls += 1
  end
end

class ApplicationSpecFailingShutdownProbe
  include LF::DI::Disposable

  def destroy : Nil
    raise "shutdown failed"
  end
end

class ApplicationSpecOrder
  @@entries = [] of String

  def self.entries : Array(String)
    @@entries
  end

  def self.reset : Nil
    @@entries.clear
  end
end

class ApplicationSpecExtension
  include LF::ApplicationExtension

  def initialize(@name : String, @trace : Array(String))
  end

  def configure(context : LF::ApplicationContext) : Nil
    @trace << "configure:#{@name}"
    name = @name
    context.register_bean(name: "extension_#{name}", type: String) do |_scope|
      name
    end
  end

  def stop : Nil
    @trace << "stop:#{@name}"
  end
end

class ApplicationSpecLifecycleExtension
  include LF::ApplicationExtension

  def initialize(@trace : Array(String))
  end

  def configure(context : LF::ApplicationContext) : Nil
    trace = @trace
    context.register_bean(name: "extension_shutdown_probe", type: ApplicationSpecShutdownProbe) do |_scope|
      ApplicationSpecShutdownProbe.new
    end
    trace << "configure:extension"
  end

  def stop : Nil
    @trace << "stop:extension"
  end
end

class ApplicationSpecFailingExtension
  include LF::ApplicationExtension

  def initialize(@trace : Array(String))
  end

  def configure(context : LF::ApplicationContext) : Nil
    context.register_bean(name: "failing_extension_probe", type: ApplicationSpecShutdownProbe) do |_scope|
      ApplicationSpecShutdownProbe.new
    end
  end

  def stop : Nil
    @trace << "stop:failing"
    raise "extension stop failed"
  end
end

class ApplicationSpecConfigureFailure < Exception
end

class ApplicationSpecFailingConfigureExtension
  include LF::ApplicationExtension

  getter stop_calls = 0

  def configure(context : LF::ApplicationContext) : Nil
    context.register_bean(name: "partial_extension_probe", type: ApplicationSpecShutdownProbe) do |_scope|
      ApplicationSpecShutdownProbe.new
    end
    context.resolve("partial_extension_probe", ApplicationSpecShutdownProbe)
    raise ApplicationSpecConfigureFailure.new("configure failed")
  end

  def stop : Nil
    @stop_calls += 1
  end
end

@[LF::ApplicationConfiguration(priority: 20)]
class ApplicationSpecHighPriorityConfiguration
  def initialize
    ApplicationSpecOrder.entries << "high"
  end
end

@[LF::ApplicationConfiguration(priority: -10)]
class ApplicationSpecLowPriorityConfiguration
  def initialize
    ApplicationSpecOrder.entries << "low"
  end
end

@[LF::ApplicationConfiguration(priority: 10)]
class ApplicationSpecConfiguration
  @[LF::DI::Bean]
  def application_spec_value : ApplicationSpecValue
    ApplicationSpecValue.new("configured")
  end

  @[LF::DI::Bean]
  def application_spec_shutdown_probe : ApplicationSpecShutdownProbe
    ApplicationSpecShutdownProbe.new
  end

  @[LF::DI::Bean]
  def application_spec_failing_shutdown_probe : ApplicationSpecFailingShutdownProbe
    ApplicationSpecFailingShutdownProbe.new
  end

  @[LF::DI::Bean]
  def application_spec_config_consumer(config_service : LF::ConfigService) : ApplicationSpecConfigConsumer
    ApplicationSpecConfigConsumer.new(config_service)
  end
end

@[LF::DI::Service]
class ApplicationSpecAutowiredService
  getter value : ApplicationSpecValue

  def initialize(@value : ApplicationSpecValue)
  end
end

@[LF::Application(priority: 5)]
class ApplicationSpecApp
  def initialize
    ApplicationSpecOrder.entries << "application"
  end

  @[LF::DI::Bean]
  def application_owned_value : String
    "owned by application"
  end
end

describe LF::ApplicationRuntime do
  it "constructs configuration providers by descending priority" do
    ApplicationSpecOrder.reset

    application = ApplicationSpecApp.bootstrap

    ApplicationSpecOrder.entries.should eq(["high", "application", "low"])
    application.shutdown
  end

  it "bootstraps the annotated application and resolves configuration beans" do
    application = ApplicationSpecApp.bootstrap

    application.should be_a(LF::ApplicationRuntime)
    application.resolve(ApplicationSpecValue).value.should eq("configured")
    application.resolve("application_owned_value", String).should eq("owned by application")

    application.shutdown
  end

  it "eagerly registers the application ConfigService singleton" do
    application = ApplicationSpecApp.bootstrap

    config = application.resolve(LF::ConfigService)
    config.should be(application.resolve("config_service", LF::ConfigService))

    application.shutdown
  end

  it "injects ConfigService through normal DI resolution" do
    application = ApplicationSpecApp.bootstrap

    consumer = application.resolve(ApplicationSpecConfigConsumer)
    consumer.config.should be(application.resolve(LF::ConfigService))

    application.shutdown
  end

  it "fails bootstrap eagerly when the selected configuration is invalid" do
    previous = ENV["OPAL_CONFIG"]?
    path = "/tmp/opal-application-invalid-config-#{Process.pid}-#{Random.rand(1_000_000)}.yml"
    File.write(path, "http: [\n")
    ENV["OPAL_CONFIG"] = path

    expect_raises(LF::ConfigService::LoadError) do
      ApplicationSpecApp.bootstrap
    end
  ensure
    File.delete(path) if path && File.exists?(path)
    if previous
      ENV["OPAL_CONFIG"] = previous
    else
      ENV.delete("OPAL_CONFIG")
    end
  end

  it "installs extensions through a controlled application context" do
    application = ApplicationSpecApp.bootstrap
    trace = [] of String
    extension = ApplicationSpecExtension.new("http", trace)

    application.install(extension).should be(extension)
    application.resolve("extension_http", String).should eq("http")
    trace.should eq(["configure:http"])

    application.shutdown
    trace.should eq(["configure:http", "stop:http"])
  end

  it "stops extensions in reverse order before DI shutdown" do
    ApplicationSpecShutdownProbe.reset
    trace = [] of String
    application = ApplicationSpecApp.bootstrap
    application.install(ApplicationSpecLifecycleExtension.new(trace))
    application.install(ApplicationSpecExtension.new("second", trace))
    application.resolve("extension_shutdown_probe", ApplicationSpecShutdownProbe)

    application.shutdown

    trace.should eq([
      "configure:extension",
      "configure:second",
      "stop:second",
      "stop:extension",
    ])
    ApplicationSpecShutdownProbe.destroy_calls.should eq(1)
  end

  it "continues extension and DI shutdown after an extension fails" do
    ApplicationSpecShutdownProbe.reset
    trace = [] of String
    application = ApplicationSpecApp.bootstrap
    application.install(ApplicationSpecExtension.new("first", trace))
    application.install(ApplicationSpecFailingExtension.new(trace))
    application.resolve("failing_extension_probe", ApplicationSpecShutdownProbe)

    error = expect_raises(LF::ApplicationRuntime::ShutdownError) do
      application.shutdown
    end

    trace.should eq([
      "configure:first",
      "stop:failing",
      "stop:first",
    ])
    error.extension_errors.size.should eq(1)
    error.extension_errors.first.message.should eq("extension stop failed")
    error.container_error.should be_nil
    ApplicationSpecShutdownProbe.destroy_calls.should eq(1)
  end

  it "cleans up and closes the runtime when extension configuration fails" do
    ApplicationSpecShutdownProbe.reset
    application = ApplicationSpecApp.bootstrap
    extension = ApplicationSpecFailingConfigureExtension.new

    expect_raises(ApplicationSpecConfigureFailure, "configure failed") do
      application.install(extension)
    end

    extension.stop_calls.should eq(1)
    ApplicationSpecShutdownProbe.destroy_calls.should eq(1)
    application.closed?.should be_true
    expect_raises(LF::ApplicationRuntime::ClosedError) do
      application.resolve(ApplicationSpecValue)
    end
  end

  it "registers DI-managed services during bootstrap" do
    application = ApplicationSpecApp.bootstrap

    service = application.resolve(ApplicationSpecAutowiredService)
    service.value.should be(application.resolve(ApplicationSpecValue))

    application.shutdown
  end

  it "keeps a bootstrapped application open until explicit shutdown" do
    ApplicationSpecShutdownProbe.reset
    application = ApplicationSpecApp.bootstrap

    application.resolve(ApplicationSpecShutdownProbe)
    ApplicationSpecShutdownProbe.destroy_calls.should eq(0)

    application.shutdown

    ApplicationSpecShutdownProbe.destroy_calls.should eq(1)
  end

  it "rejects resolution after shutdown" do
    application = ApplicationSpecApp.bootstrap
    application.shutdown

    expect_raises(LF::ApplicationRuntime::ClosedError) do
      application.resolve(ApplicationSpecValue)
    end
  end

  it "rejects repeated shutdown" do
    application = ApplicationSpecApp.bootstrap
    application.shutdown

    expect_raises(LF::ApplicationRuntime::AlreadyClosedError) do
      application.shutdown
    end
  end

  it "returns the run block result and shuts down" do
    ApplicationSpecShutdownProbe.reset

    result = ApplicationSpecApp.run do |application|
      application.resolve(ApplicationSpecShutdownProbe)
      "done"
    end

    result.should eq("done")
    ApplicationSpecShutdownProbe.destroy_calls.should eq(1)
  end

  it "re-raises a run block failure after successful shutdown" do
    ApplicationSpecShutdownProbe.reset

    expect_raises(Exception, "run failed") do
      ApplicationSpecApp.run do |application|
        application.resolve(ApplicationSpecShutdownProbe)
        raise "run failed"
      end
    end

    ApplicationSpecShutdownProbe.destroy_calls.should eq(1)
  end

  it "preserves block and shutdown failures in RunError" do
    error = expect_raises(LF::ApplicationRuntime::RunError) do
      ApplicationSpecApp.run do |application|
        application.resolve(ApplicationSpecFailingShutdownProbe)
        raise "run failed"
      end
    end

    error.block_error.message.should eq("run failed")
    error.shutdown_error.should be_a(LF::DI::BeanDestructionError)
  end
end
