require "./spec_helper"
require "../src/opal"

class ApplicationSpecValue
  getter value : String

  def initialize(@value : String)
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
