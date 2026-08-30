require "../../../src/opal/data"

class NilDeleteIdEntity
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  def initialize
    @id = nil
  end
end

def nil_delete_id(manager : LF::Data::EntityManager)
  manager.delete(NilDeleteIdEntity, nil)
end

nil_delete_id(Pointer(LF::Data::EntityManager).null.value)
