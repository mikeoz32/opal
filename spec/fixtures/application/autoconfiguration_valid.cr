require "../../../src/opal"

module LF::AutoConfig
  annotation ValidFixture
  end
end

@[LF::ApplicationAutoConfiguration(
  enabled_by: LF::AutoConfig::ValidFixture,
  priority: 10_u64
)]
class ValidFixtureExtension
  include LF::ApplicationExtension

  def configure(context : LF::ApplicationContext) : Nil
  end

  def stop : Nil
  end
end

@[LF::ApplicationAutoConfiguration(enabled_by: LF::AutoConfig::ValidFixture)]
class DefaultNilConstructorExtension
  include LF::ApplicationExtension

  def initialize(value : String? = nil)
  end

  def configure(context : LF::ApplicationContext) : Nil
  end

  def stop : Nil
  end
end

@[LF::ApplicationAutoConfiguration(enabled_by: LF::AutoConfig::ValidFixture)]
class UntypedSplatConstructorExtension
  include LF::ApplicationExtension

  def initialize(*values)
  end

  def configure(context : LF::ApplicationContext) : Nil
  end

  def stop : Nil
  end
end

@[LF::Application]
@[LF::AutoConfig::ValidFixture]
class ValidAutoconfigurationApp
end

ValidAutoconfigurationApp.bootstrap
