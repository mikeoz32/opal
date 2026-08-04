require "../../../src/opal"

module LF::AutoConfig
  annotation InheritedConstructorFixture
  end
end

abstract class RequiresArgumentsExtensionBase
  include LF::ApplicationExtension

  def initialize(value : String)
  end

  def configure(context : LF::ApplicationContext) : Nil
  end

  def stop : Nil
  end
end

@[LF::ApplicationAutoConfiguration(enabled_by: LF::AutoConfig::InheritedConstructorFixture)]
class InheritedRequiresArgumentsExtension < RequiresArgumentsExtensionBase
end

@[LF::Application]
@[LF::AutoConfig::InheritedConstructorFixture]
class InheritedConstructorApp
end

InheritedConstructorApp.bootstrap
