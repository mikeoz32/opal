require "../../../src/opal/data"

class InvalidCollectionOwner
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::HasMany(foreign_key: "owner_id")]
  getter children : String = "not a collection"

  def initialize(@id : Int64)
  end
end
