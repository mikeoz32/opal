require "../../../src/opal/data"

class CrossEntityStringId
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : String

  def initialize(@id : String)
  end
end

class CrossEntityIntId
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  def initialize(@id : Int64)
  end
end

def cross_entity_find(manager : LF::Data::EntityManager, other : CrossEntityStringId)
  manager.find(CrossEntityIntId, other.id)
end

cross_entity_find(
  Pointer(LF::Data::EntityManager).null.value,
  CrossEntityStringId.new("wrong")
)
