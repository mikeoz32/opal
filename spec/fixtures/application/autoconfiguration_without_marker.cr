require "../../../src/opal"

module LF::AutoConfig
  annotation AbsentFixture
  end
end

@[LF::ApplicationAutoConfiguration(enabled_by: LF::AutoConfig::AbsentFixture)]
class AbsentMarkerExtension
  include LF::ApplicationExtension

  def configure(context : LF::ApplicationContext) : Nil
    raise "Absent-marker extension must not be installed"
  end

  def stop : Nil
    raise "Absent-marker extension must not be stopped"
  end
end

@[LF::Application]
class NoAutoconfigurationMarkerApp
end

runtime = NoAutoconfigurationMarkerApp.bootstrap
runtime.shutdown
