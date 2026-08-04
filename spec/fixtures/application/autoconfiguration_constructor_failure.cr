require "../../../src/opal"

module LF::AutoConfig
  annotation ConstructorFailureFixture
  end
end

class ConstructorFailureTrace
  @@entries = [] of String

  def self.entries : Array(String)
    @@entries
  end
end

class AutoconfigurationConstructorFailure < Exception
end

@[LF::ApplicationAutoConfiguration(
  enabled_by: LF::AutoConfig::ConstructorFailureFixture,
  priority: 20
)]
class InstalledBeforeConstructorFailure
  include LF::ApplicationExtension

  def configure(context : LF::ApplicationContext) : Nil
    ConstructorFailureTrace.entries << "configure:first"
  end

  def stop : Nil
    ConstructorFailureTrace.entries << "stop:first"
  end
end

@[LF::ApplicationAutoConfiguration(
  enabled_by: LF::AutoConfig::ConstructorFailureFixture,
  priority: 10
)]
class FailingAutoconfigurationConstructor
  include LF::ApplicationExtension

  def initialize
    raise AutoconfigurationConstructorFailure.new("constructor failed")
  end

  def configure(context : LF::ApplicationContext) : Nil
  end

  def stop : Nil
  end
end

@[LF::Application]
@[LF::AutoConfig::ConstructorFailureFixture]
class ConstructorFailureApp
end

begin
  ConstructorFailureApp.bootstrap
  raise "Bootstrap unexpectedly returned"
rescue error : AutoconfigurationConstructorFailure
  unless error.message == "constructor failed"
    raise "Bootstrap replaced the constructor error: #{error.inspect}"
  end
end

unless ConstructorFailureTrace.entries == ["configure:first", "stop:first"]
  raise "Unexpected constructor-failure cleanup: #{ConstructorFailureTrace.entries.inspect}"
end
