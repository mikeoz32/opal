require "../../../src/opal/data"

class ValidTypedIdEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : String

  def initialize(@id : String)
  end
end

def valid_typed_id_operations(manager : LF::Data::EntityManager)
  manager.find(ValidTypedIdEntity, "valid")
  manager.delete(ValidTypedIdEntity, "valid")
end

valid_typed_id_operations(Pointer(LF::Data::EntityManager).null.value)
