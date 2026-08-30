require "../../../src/opal/data"

class MissingForeignKeyParent
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  def initialize(@id : Int64)
  end
end

class MissingForeignKeyChild
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::BelongsTo(foreign_key: "parent_id")]
  property parent : MissingForeignKeyParent?

  def initialize(@id : Int64, @parent : MissingForeignKeyParent? = nil)
  end
end
