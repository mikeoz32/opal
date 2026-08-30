require "../../../src/opal/data"

class InvalidCascadeFlagParent
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : String

  def initialize(@id : String)
  end
end

class InvalidCascadeFlagChild
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : String

  getter parent_id : String

  @[LF::Data::BelongsTo(
    foreign_key: "parent_id",
    cascade_persist: "yes",
  )]
  property parent : InvalidCascadeFlagParent?

  def initialize(@id : String, @parent_id : String)
    @parent = nil
  end
end
