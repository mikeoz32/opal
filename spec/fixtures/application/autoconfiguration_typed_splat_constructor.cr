require "../../../src/opal"

module LF::AutoConfig
  annotation TypedSplatConstructorFixture
  end
end

@[LF::ApplicationAutoConfiguration(enabled_by: LF::AutoConfig::TypedSplatConstructorFixture)]
class TypedSplatConstructorExtension
  include LF::ApplicationExtension

  def initialize(*values : String)
  end

  def configure(context : LF::ApplicationContext) : Nil
  end

  def stop : Nil
  end
end

@[LF::Application]
@[LF::AutoConfig::TypedSplatConstructorFixture]
class TypedSplatConstructorApp
end
