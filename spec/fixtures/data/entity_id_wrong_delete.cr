require "../../../src/opal/data"

class WrongDeleteIdEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  def initialize(@id : Int64)
  end
end

def wrong_delete_id(manager : LF::Data::EntityManager)
  manager.delete(WrongDeleteIdEntity, "wrong")
end

wrong_delete_id(Pointer(LF::Data::EntityManager).null.value)
