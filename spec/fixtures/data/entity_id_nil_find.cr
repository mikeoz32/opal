require "../../../src/opal/data"

class NilFindIdEntity
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  def initialize
    @id = nil
  end
end

def nil_find_id(manager : LF::Data::EntityManager)
  manager.find(NilFindIdEntity, nil)
end

nil_find_id(Pointer(LF::Data::EntityManager).null.value)
