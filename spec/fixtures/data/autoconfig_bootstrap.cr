require "../../../src/opal"
require "../../../src/opal/autoconfig/data"
require "sqlite3"

class DataAutoconfigBootstrapProbe
  @@source : LF::Data::DataSource?
  @@stopped = false

  def self.source=(source : LF::Data::DataSource)
    @@source = source
  end

  def self.source : LF::Data::DataSource
    @@source || raise "Data autoconfiguration did not run before the probe"
  end

  def self.stopped=(value : Bool)
    @@stopped = value
  end

  def self.stopped? : Bool
    @@stopped
  end
end

@[LF::ApplicationAutoConfiguration(
  enabled_by: LF::AutoConfig::Data,
  priority: 99
)]
class DataAutoconfigBootstrapProbeExtension
  include LF::ApplicationExtension

  def configure(context : LF::ApplicationContext) : Nil
    source = context.resolve(LF::Data::DataSource)
    source.transaction { |manager| manager.connection.scalar("SELECT 1") }
    DataAutoconfigBootstrapProbe.source = source
  end

  def stop : Nil
    raise "DataSource closed before lower-priority extension stopped" if DataAutoconfigBootstrapProbe.source.closed?
    DataAutoconfigBootstrapProbe.stopped = true
  end
end

@[LF::Application]
@[LF::AutoConfig::Data]
class DataAutoconfigBootstrapApplication
end

runtime = DataAutoconfigBootstrapApplication.bootstrap
source = runtime.resolve(LF::Data::DataSource)
raise "bootstrap returned a different DataSource" unless source.same?(DataAutoconfigBootstrapProbe.source)

runtime.shutdown
raise "lower-priority extension was not stopped" unless DataAutoconfigBootstrapProbe.stopped?
raise "DataSource remained open after shutdown" unless source.closed?
