require "../../../src/opal"

module LF::AutoConfig
  annotation ConfigureFailureFixture
  end
end

class ConfigureFailureTrace
  @@entries = [] of String

  def self.entries : Array(String)
    @@entries
  end
end

class ConfigureFailureDisposable
  include LF::DI::Disposable

  def initialize(@label : String)
  end

  def destroy : Nil
    ConfigureFailureTrace.entries << "destroy:#{@label}"
  end
end

class AutoconfigurationConfigureFailure < Exception
end

@[LF::ApplicationAutoConfiguration(
  enabled_by: LF::AutoConfig::ConfigureFailureFixture,
  priority: 20
)]
class InstalledBeforeConfigureFailure
  include LF::ApplicationExtension

  def configure(context : LF::ApplicationContext) : Nil
    ConfigureFailureTrace.entries << "configure:first"
    context.register_bean(name: "first_probe", type: ConfigureFailureDisposable) do |_scope|
      ConfigureFailureDisposable.new("first")
    end
    context.resolve("first_probe", ConfigureFailureDisposable)
  end

  def stop : Nil
    ConfigureFailureTrace.entries << "stop:first"
  end
end

@[LF::ApplicationAutoConfiguration(
  enabled_by: LF::AutoConfig::ConfigureFailureFixture,
  priority: 10
)]
class FailingConfigureExtension
  include LF::ApplicationExtension

  def configure(context : LF::ApplicationContext) : Nil
    ConfigureFailureTrace.entries << "configure:failing"
    context.register_bean(name: "failing_probe", type: ConfigureFailureDisposable) do |_scope|
      ConfigureFailureDisposable.new("failing")
    end
    context.resolve("failing_probe", ConfigureFailureDisposable)
    raise AutoconfigurationConfigureFailure.new("configure failed")
  end

  def stop : Nil
    ConfigureFailureTrace.entries << "stop:failing"
  end
end

@[LF::Application]
@[LF::AutoConfig::ConfigureFailureFixture]
class ConfigureFailureApp
end

begin
  ConfigureFailureApp.bootstrap
  raise "Bootstrap unexpectedly returned"
rescue error : AutoconfigurationConfigureFailure
  unless error.message == "configure failed"
    raise "Bootstrap replaced the configure error: #{error.inspect}"
  end
end

expected = [
  "configure:first",
  "configure:failing",
  "stop:failing",
  "stop:first",
  "destroy:failing",
  "destroy:first",
]
unless ConfigureFailureTrace.entries == expected
  raise "Unexpected configure-failure cleanup: #{ConfigureFailureTrace.entries.inspect}"
end
