require "../../../src/opal/data"

class BulkUpdateWrongValueFixture
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  getter title : String

  def initialize(@id, @title)
  end
end

def invalid_bulk_update(manager : LF::Data::EntityManager)
  manager.update(BulkUpdateWrongValueFixture)
    .set(BulkUpdateWrongValueFixture::Fields.title, 2_i64)
end

invalid_bulk_update(Pointer(LF::Data::EntityManager).null.value)
