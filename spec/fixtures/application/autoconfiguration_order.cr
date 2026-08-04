require "../../../src/opal"

module LF::AutoConfig
  annotation OrderFixture
  end

  annotation DisabledOrderFixture
  end
end

class AutoconfigurationOrderTrace
  @@entries = [] of String

  def self.entries : Array(String)
    @@entries
  end
end

abstract class OrderFixtureExtension
  include LF::ApplicationExtension

  def configure(context : LF::ApplicationContext) : Nil
    AutoconfigurationOrderTrace.entries << "configure:#{label}"
  end

  def stop : Nil
    AutoconfigurationOrderTrace.entries << "stop:#{label}"
  end

  abstract def label : String
end

@[LF::ApplicationAutoConfiguration(enabled_by: LF::AutoConfig::OrderFixture, priority: 20)]
class ZHighOrderExtension < OrderFixtureExtension
  def label : String
    "z_high"
  end
end

@[LF::ApplicationAutoConfiguration(enabled_by: LF::AutoConfig::OrderFixture, priority: 20)]
class AHighOrderExtension < OrderFixtureExtension
  def label : String
    "a_high"
  end
end

@[LF::ApplicationAutoConfiguration(enabled_by: LF::AutoConfig::OrderFixture, priority: -5)]
class LowOrderExtension < OrderFixtureExtension
  def label : String
    "low"
  end
end

@[LF::ApplicationAutoConfiguration(
  enabled_by: LF::AutoConfig::DisabledOrderFixture,
  priority: 100
)]
class DisabledOrderExtension < OrderFixtureExtension
  def label : String
    "disabled"
  end
end

@[LF::Application]
@[LF::AutoConfig::OrderFixture]
class OrderedAutoconfigurationApp
end

runtime = OrderedAutoconfigurationApp.bootstrap
configured = AutoconfigurationOrderTrace.entries
expected_configuration = [
  "configure:a_high",
  "configure:z_high",
  "configure:low",
]
unless configured == expected_configuration
  raise "Unexpected autoconfiguration order: #{configured.inspect}"
end

runtime.shutdown
expected_shutdown = expected_configuration + [
  "stop:low",
  "stop:z_high",
  "stop:a_high",
]
unless AutoconfigurationOrderTrace.entries == expected_shutdown
  raise "Unexpected autoconfiguration shutdown: #{AutoconfigurationOrderTrace.entries.inspect}"
end
