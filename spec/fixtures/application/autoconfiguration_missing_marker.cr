require "../../../src/opal"

@[LF::ApplicationAutoConfiguration]
class MissingMarkerExtension
  include LF::ApplicationExtension

  def configure(context : LF::ApplicationContext) : Nil
  end

  def stop : Nil
  end
end

@[LF::Application]
class MissingMarkerApp
end
