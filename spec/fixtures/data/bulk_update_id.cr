require "../../../src/opal/data"

class BulkUpdateIdFixture
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  def initialize(@id)
  end
end

def invalid_bulk_update(manager : LF::Data::EntityManager)
  manager.update(BulkUpdateIdFixture)
    .set(BulkUpdateIdFixture::Fields.id, 2_i64)
end

invalid_bulk_update(Pointer(LF::Data::EntityManager).null.value)
