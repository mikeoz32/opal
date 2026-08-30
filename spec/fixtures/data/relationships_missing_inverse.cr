require "../../../src/opal/data"

class MissingInverseParent
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : String

  @[LF::Data::HasMany(foreign_key: "parent_id")]
  getter children : Array(MissingInverseChild) = [] of MissingInverseChild

  def initialize(@id : String)
  end
end

class MissingInverseChild
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : String

  getter parent_id : String

  def initialize(@id : String, @parent_id : String)
  end
end
