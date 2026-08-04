require "../../../src/opal/data"

class BulkUpdateVersionFixture
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::Version]
  getter version : Int64 = 0_i64

  def initialize(@id)
  end
end

def invalid_bulk_update(manager : LF::Data::EntityManager)
  manager.update(BulkUpdateVersionFixture)
    .set(BulkUpdateVersionFixture::Fields.version, 2_i64)
end

invalid_bulk_update(Pointer(LF::Data::EntityManager).null.value)
