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
dialects with transactional DDL. The runner pins one datasource connection for
the entire migration session. PostgreSQL acquires a session advisory lock,
namespaced by the current database and application lock namespace, before
history planning and releases it on every exit path. SQLite explicitly uses
transactional history conflict reconciliation rather than pretending to own an
engine advisory lock. A dialect without both transactional DDL and a safe
migration-lock strategy fails before history SQL runs.

`MigrationRunner` accepts `lock_namespace` and `lock_timeout`. A timeout raises
`MigrationLockTimeoutError`; if migration execution and lock cleanup both fail,
`MigrationLockCleanupError` preserves both exceptions. Schema and history
statements use the DataSource listener stream.

Applications may run migrations as a deployment step or enable startup
migrations through Data autoconfiguration. Explicit, read-only schema diff and
Crystal migration source generation are documented in the
[schema generation guide](schema-generation.md). There is no `down`,
entity-driven schema inference, destructive auto-sync, or source checksum.
