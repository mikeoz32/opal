require "../../../src/opal/data"
require "../../../src/opal/data/dialects/sqlite"

class BulkDeleteOwnerFixture
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  def initialize(@id)
  end
end

class BulkDeleteForeignFixture
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  def initialize(@id)
  end
end

def invalid_bulk_delete(manager : LF::Data::EntityManager)
  manager.delete(BulkDeleteOwnerFixture)
    .where(BulkDeleteForeignFixture::Fields.id.eq(1_i64))
    .execute
end

invalid_bulk_delete(Pointer(LF::Data::EntityManager).null.value)
