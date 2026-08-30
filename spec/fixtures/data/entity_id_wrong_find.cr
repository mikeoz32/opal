require "../../../src/opal/data"

class WrongFindIdEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  def initialize(@id : Int64)
  end
end

def wrong_find_id(manager : LF::Data::EntityManager)
  manager.find(WrongFindIdEntity, "wrong")
end

wrong_find_id(Pointer(LF::Data::EntityManager).null.value)
