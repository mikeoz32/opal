require "../../../src/opal/data"

def invalid_bulk_update(manager : LF::Data::EntityManager)
  manager.update(Int32).execute
end

invalid_bulk_update(Pointer(LF::Data::EntityManager).null.value)
