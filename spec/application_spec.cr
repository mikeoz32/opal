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

@[LF::Application::Configuration]
class ApplicationSpecConfiguration
  include LF::DI::ApplicationConfig

  @[LF::DI::Bean]
  def application_spec_value : ApplicationSpecValue
    ApplicationSpecValue.new("configured")
  end

  @[LF::DI::Bean]
  def application_spec_shutdown_probe : ApplicationSpecShutdownProbe
    ApplicationSpecShutdownProbe.new
  end
end

@[LF::DI::Service]
class ApplicationSpecAutowiredService
  getter value : ApplicationSpecValue

  def initialize(@value : ApplicationSpecValue)
  end
end

class ApplicationSpecSubclass < LF::Application
end

describe LF::Application do
  it "owns and exposes a root annotation application context" do
    application = LF::Application.bootstrap

    application.context.should be_a(LF::DI::AnnotationApplicationContext)

    application.shutdown
  end

  it "uses the exact root context supplied by the caller" do
    context = LF::DI::AnnotationApplicationContext.new

    application = LF::Application.bootstrap(context)

    application.context.should be(context)

    application.shutdown
  end

  it "registers annotated application configs and autowired services" do
    application = LF::Application.bootstrap

    value = application.context.get_bean("application_spec_value", ApplicationSpecValue)
    service = application.context.get_bean("application_spec_autowired_service", ApplicationSpecAutowiredService)

    value.value.should eq("configured")
    service.value.should be(value)

    application.shutdown
  end

  it "bootstraps the receiver subclass without an annotation" do
    application : ApplicationSpecSubclass = ApplicationSpecSubclass.bootstrap

    application.should be_a(ApplicationSpecSubclass)
    application.context.get_bean("application_spec_value", ApplicationSpecValue).value.should eq("configured")

    application.shutdown
  end

  it "keeps a bootstrapped application live until explicit shutdown" do
    ApplicationSpecShutdownProbe.reset
    application = LF::Application.bootstrap

    application.context.get_bean("application_spec_shutdown_probe", ApplicationSpecShutdownProbe)
    ApplicationSpecShutdownProbe.destroy_calls.should eq(0)

    application.shutdown

    ApplicationSpecShutdownProbe.destroy_calls.should eq(1)
  end

  it "shuts down after a run block completes" do
    ApplicationSpecShutdownProbe.reset

    LF::Application.run do |application|
      application.context.get_bean("application_spec_shutdown_probe", ApplicationSpecShutdownProbe)
      ApplicationSpecShutdownProbe.destroy_calls.should eq(0)
    end

    ApplicationSpecShutdownProbe.destroy_calls.should eq(1)
  end

  it "shuts down when a run block raises" do
    ApplicationSpecShutdownProbe.reset

    expect_raises(Exception, "run failed") do
      LF::Application.run do |application|
        application.context.get_bean("application_spec_shutdown_probe", ApplicationSpecShutdownProbe)
        raise "run failed"
      end
    end

    ApplicationSpecShutdownProbe.destroy_calls.should eq(1)
  end
end
