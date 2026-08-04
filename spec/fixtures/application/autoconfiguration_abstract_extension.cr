require "../../../src/opal"

module LF::AutoConfig
  annotation AbstractExtensionFixture
  end
end

@[LF::ApplicationAutoConfiguration(enabled_by: LF::AutoConfig::AbstractExtensionFixture)]
abstract class AbstractFixtureExtension
  include LF::ApplicationExtension

  def configure(context : LF::ApplicationContext) : Nil
  end

  def stop : Nil
  end
end

@[LF::Application]
@[LF::AutoConfig::AbstractExtensionFixture]
class AbstractExtensionApp
end

AbstractExtensionApp.bootstrap
