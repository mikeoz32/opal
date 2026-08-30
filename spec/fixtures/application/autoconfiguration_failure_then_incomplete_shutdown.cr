require "../../../src/opal"

module LF::AutoConfig
  annotation FailureThenIncompleteShutdownFixture
  end
end

class FailureThenIncompleteShutdownTrace
  @@entries = [] of String

  def self.entries : Array(String)
    @@entries
  end
end

class FailureThenIncompleteShutdownProbe
  include LF::DI::Disposable

  def destroy : Nil
    FailureThenIncompleteShutdownTrace.entries << "destroy:probe"
  end
end

class FailureThenIncompleteShutdownStopError < Exception
  include LF::ApplicationExtension::StopIncomplete
end

class FailureThenIncompleteShutdownConstructorError < Exception
end

@[LF::ApplicationAutoConfiguration(
  enabled_by: LF::AutoConfig::FailureThenIncompleteShutdownFixture,
  priority: 20
)]
class InstalledIncompleteShutdownExtension
  include LF::ApplicationExtension

  @@can_stop = false
  @@stop_calls = 0

  def self.allow_stop : Nil
    @@can_stop = true
  end

  def self.stop_calls : Int32
    @@stop_calls
  end

  def configure(context : LF::ApplicationContext) : Nil
    FailureThenIncompleteShutdownTrace.entries << "configure"
    context.register_bean(
      name: "failure_then_incomplete_shutdown_probe",
      type: FailureThenIncompleteShutdownProbe
    ) do |_scope|
      FailureThenIncompleteShutdownProbe.new
    end
    context.resolve("failure_then_incomplete_shutdown_probe", FailureThenIncompleteShutdownProbe)
  end

  def stop : Nil
    @@stop_calls += 1
    FailureThenIncompleteShutdownTrace.entries << "stop"
    unless @@can_stop
      raise FailureThenIncompleteShutdownStopError.new("installed extension still active")
    end
  end
end

@[LF::ApplicationAutoConfiguration(
  enabled_by: LF::AutoConfig::FailureThenIncompleteShutdownFixture,
  priority: 10
)]
class LaterFailingConstructorExtension
  include LF::ApplicationExtension

  def initialize
    raise FailureThenIncompleteShutdownConstructorError.new("constructor failed")
  end

  def configure(context : LF::ApplicationContext) : Nil
  end

  def stop : Nil
  end
end

@[LF::Application]
@[LF::AutoConfig::FailureThenIncompleteShutdownFixture]
class FailureThenIncompleteShutdownApp
end

begin
  FailureThenIncompleteShutdownApp.bootstrap
  raise "Bootstrap unexpectedly returned"
rescue error : LF::ApplicationRuntime::InstallError
  unless error.configure_error.is_a?(FailureThenIncompleteShutdownConstructorError)
    raise "Bootstrap lost the constructor failure: #{error.configure_error.inspect}"
  end
  runtime = error.pending_runtime || raise "Bootstrap lost the newly pending runtime"
  raise "Installed extension stop count was unexpected" unless InstalledIncompleteShutdownExtension.stop_calls == 1
  unless FailureThenIncompleteShutdownTrace.entries == ["configure", "stop"]
    raise "Bootstrap destroyed pending resources: #{FailureThenIncompleteShutdownTrace.entries.inspect}"
  end

  InstalledIncompleteShutdownExtension.allow_stop
  runtime.shutdown

  unless FailureThenIncompleteShutdownTrace.entries == ["configure", "stop", "stop", "destroy:probe"]
    raise "Unexpected explicit retry cleanup: #{FailureThenIncompleteShutdownTrace.entries.inspect}"
  end
end
