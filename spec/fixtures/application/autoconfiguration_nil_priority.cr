require "../../../src/opal"

module LF::AutoConfig
  annotation NilPriorityFixture
  end
end

@[LF::ApplicationAutoConfiguration(
  enabled_by: LF::AutoConfig::NilPriorityFixture,
  priority: nil
)]
class NilPriorityExtension
  include LF::ApplicationExtension

  def configure(context : LF::ApplicationContext) : Nil
  end

  def stop : Nil
  end
end
