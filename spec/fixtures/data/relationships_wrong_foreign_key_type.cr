require "../../../src/opal/data"

class WrongForeignKeyTypeParent
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  def initialize(@id : Int64)
  end
end

class WrongForeignKeyTypeChild
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  getter parent_id : String

  @[LF::Data::BelongsTo(foreign_key: "parent_id")]
  property parent : WrongForeignKeyTypeParent?

  def initialize(
    @id : Int64,
    @parent_id : String,
    @parent : WrongForeignKeyTypeParent? = nil,
  )
  end
end
