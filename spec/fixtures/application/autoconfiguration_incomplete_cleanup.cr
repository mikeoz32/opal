require "../../../src/opal"

module LF::AutoConfig
  annotation IncompleteCleanupFixture
  end
end

class IncompleteCleanupTrace
  @@entries = [] of String

  def self.entries : Array(String)
    @@entries
  end
end

class IncompleteCleanupProbe
  include LF::DI::Disposable

  def destroy : Nil
    IncompleteCleanupTrace.entries << "destroy:probe"
  end
end

class IncompleteCleanupConfigureError < Exception
end

class IncompleteCleanupStopError < Exception
  include LF::ApplicationExtension::StopIncomplete
end

@[LF::ApplicationAutoConfiguration(
  enabled_by: LF::AutoConfig::IncompleteCleanupFixture,
  priority: 10
)]
class IncompleteCleanupExtension
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
    IncompleteCleanupTrace.entries << "configure"
    context.register_bean(name: "incomplete_cleanup_probe", type: IncompleteCleanupProbe) do |_scope|
      IncompleteCleanupProbe.new
    end
    context.resolve("incomplete_cleanup_probe", IncompleteCleanupProbe)
    raise IncompleteCleanupConfigureError.new("configure failed")
  end

  def stop : Nil
    @@stop_calls += 1
    IncompleteCleanupTrace.entries << "stop"
    raise IncompleteCleanupStopError.new("extension still active") unless @@can_stop
  end
end

@[LF::Application]
@[LF::AutoConfig::IncompleteCleanupFixture]
class IncompleteCleanupApp
end

begin
  IncompleteCleanupApp.bootstrap
  raise "Bootstrap unexpectedly returned"
rescue error : LF::ApplicationRuntime::InstallError
  runtime = error.pending_runtime || raise "InstallError lost the pending runtime"
  raise "Bootstrap retried incomplete stop" unless IncompleteCleanupExtension.stop_calls == 1
  raise "Pending runtime was reported closed" if runtime.closed?
  raise "Pending runtime state was lost" unless runtime.shutdown_pending?
  unless IncompleteCleanupTrace.entries == ["configure", "stop"]
    raise "Bootstrap destroyed pending resources: #{IncompleteCleanupTrace.entries.inspect}"
  end

  IncompleteCleanupExtension.allow_stop
  runtime.shutdown

  raise "Shutdown did not close the retained runtime" unless runtime.closed?
  unless IncompleteCleanupTrace.entries == ["configure", "stop", "stop", "destroy:probe"]
    raise "Unexpected retry cleanup: #{IncompleteCleanupTrace.entries.inspect}"
  end
end
