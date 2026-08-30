# Data Migrations

Migrations are explicit, ordered, and forward-only:

```crystal
class CreateTodos < LF::Data::Migration
  def version : Int64
    1_i64
  end

  def name : String
    "create_todos"
  end

  def up(schema : LF::Data::SchemaEditor) : Nil
    schema.create_table("todos") do |table|
      table.generated_id("id")
      table.string("title", null: false)
    end
  end
end

migrations = LF::Data::MigrationSet.new(CreateTodos.new)
LF::Data::MigrationRunner.new(source).run(migrations)
```

The runner validates positive, unique, strictly ascending versions and records
version/name history in `_lf_migrations`. Repeated runs skip exact applied
migrations; renamed or unknown applied versions refuse startup.

Each pending migration and its history row share one database transaction on
dialects with transactional DDL. Concurrent SQLite runners reconcile through
the unique history version. Schema and history statements use the DataSource
listener stream.

Applications may run migrations as a deployment step or enable startup
migrations through Data autoconfiguration. V1 has no `down`, schema diff,
entity-driven schema generation, destructive auto-sync, or source checksums.
