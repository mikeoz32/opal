require "../../../src/opal/data"

class InvalidBelongsToRemoveParent
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  def initialize(@id : Int64)
  end
end

class InvalidBelongsToRemoveChild
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  getter parent_id : Int64

  @[LF::Data::BelongsTo(
    foreign_key: "parent_id",
    cascade_remove: true,
  )]
  property parent : InvalidBelongsToRemoveParent?

  def initialize(
    @id : Int64,
    @parent_id : Int64,
    @parent : InvalidBelongsToRemoveParent? = nil,
  )
  end
end
