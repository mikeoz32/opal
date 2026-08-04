require "../../../src/opal"

class NotAnAnnotation
end

@[LF::ApplicationAutoConfiguration(enabled_by: NotAnAnnotation)]
class NonAnnotationMarkerExtension
  include LF::ApplicationExtension

  def configure(context : LF::ApplicationContext) : Nil
  end

  def stop : Nil
  end
end
