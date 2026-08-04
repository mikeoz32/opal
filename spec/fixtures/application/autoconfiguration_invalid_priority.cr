require "../../../src/opal"

module LF::AutoConfig
  annotation InvalidPriorityFixture
  end
end

@[LF::ApplicationAutoConfiguration(
  enabled_by: LF::AutoConfig::InvalidPriorityFixture,
  priority: 1.5
)]
class InvalidPriorityExtension
  include LF::ApplicationExtension

  def configure(context : LF::ApplicationContext) : Nil
  end

  def stop : Nil
  end
end

@[LF::Application]
class InvalidPriorityApp
end
