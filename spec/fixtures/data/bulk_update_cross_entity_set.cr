require "../../../src/opal/data"

class BulkUpdateOwnerFixture
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  getter title : String

  def initialize(@id, @title)
  end
end

class BulkUpdateForeignFixture
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  getter title : String

  def initialize(@id, @title)
  end
end

def invalid_bulk_update(manager : LF::Data::EntityManager)
  manager.update(BulkUpdateOwnerFixture)
    .set(BulkUpdateForeignFixture::Fields.title, "foreign")
end

invalid_bulk_update(Pointer(LF::Data::EntityManager).null.value)
