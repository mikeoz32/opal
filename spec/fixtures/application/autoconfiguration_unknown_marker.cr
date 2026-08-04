require "../../../src/opal"

@[LF::ApplicationAutoConfiguration(enabled_by: MissingAutoconfigurationMarker)]
class UnknownMarkerExtension
  include LF::ApplicationExtension

  def configure(context : LF::ApplicationContext) : Nil
  end

  def stop : Nil
  end
end
