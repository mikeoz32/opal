require "../../../src/opal"

module LF::AutoConfig
  annotation RequiresArgumentsFixture
  end
end

@[LF::ApplicationAutoConfiguration(enabled_by: LF::AutoConfig::RequiresArgumentsFixture)]
class RequiresArgumentsExtension
  include LF::ApplicationExtension

  def initialize(value : String)
  end

  def configure(context : LF::ApplicationContext) : Nil
  end

  def stop : Nil
  end
end

@[LF::Application]
@[LF::AutoConfig::RequiresArgumentsFixture]
class RequiresArgumentsApp
end
