require "../../../src/opal"

module LF::AutoConfig
  annotation FalsePriorityFixture
  end
end

@[LF::ApplicationAutoConfiguration(
  enabled_by: LF::AutoConfig::FalsePriorityFixture,
  priority: false
)]
class FalsePriorityExtension
  include LF::ApplicationExtension

  def configure(context : LF::ApplicationContext) : Nil
  end

  def stop : Nil
  end
end
