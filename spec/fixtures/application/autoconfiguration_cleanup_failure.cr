require "../../../src/opal"

module LF::AutoConfig
  annotation CleanupFailureFixture
  end
end

class CleanupFailureTrace
  @@entries = [] of String

  def self.entries : Array(String)
    @@entries
  end
end

class CleanupFixtureConfigureFailure < Exception
end

class CleanupFixtureStopFailure < Exception
end

@[LF::ApplicationAutoConfiguration(enabled_by: LF::AutoConfig::CleanupFailureFixture)]
class ConfigureAndStopFailingExtension
  include LF::ApplicationExtension

  def configure(context : LF::ApplicationContext) : Nil
    CleanupFailureTrace.entries << "configure"
    raise CleanupFixtureConfigureFailure.new("configure failed")
  end

  def stop : Nil
    CleanupFailureTrace.entries << "stop"
    raise CleanupFixtureStopFailure.new("stop failed")
  end
end

@[LF::Application]
@[LF::AutoConfig::CleanupFailureFixture]
class CleanupFailureApp
end

begin
  CleanupFailureApp.bootstrap
  raise "Bootstrap unexpectedly returned"
rescue error : LF::ApplicationRuntime::InstallError
  unless error.configure_error.is_a?(CleanupFixtureConfigureFailure)
    raise "InstallError lost configure failure: #{error.configure_error.inspect}"
  end
  unless error.cleanup_errors.size == 1 &&
         error.cleanup_errors.first.is_a?(CleanupFixtureStopFailure)
    raise "InstallError lost cleanup failure: #{error.cleanup_errors.inspect}"
  end
end

unless CleanupFailureTrace.entries == ["configure", "stop"]
  raise "Unexpected cleanup-failure trace: #{CleanupFailureTrace.entries.inspect}"
end
