# Data 08: Forward-Only Migrations

> **For Codex:** REQUIRED SKILLS: `executing-plans`,
> `test-driven-development`, `systematic-debugging`, and
> `verification-before-completion`.

**Goal:** Add explicit compiled migrations, a portable schema-operation model,
SQLite rendering, and transactional migration history.

**Architecture:** Migrations are separate from entity mapping. Entity metadata
never creates or synchronizes schema. Applications explicitly construct a
`MigrationSet`; a runner executes pending forward migrations through the same
DataSource infrastructure.

**Prerequisite:** Plans 02 and 03 are merged. Entity mapping and Unit of Work
are not required.

---

## Public API

```crystal
class CreateTodos < LF::Data::Migration
  def version : Int64
    2026072801_i64
  end

  def name : String
    "create_todos"
  end

  def up(schema : LF::Data::SchemaEditor) : Nil
    schema.create_table("todo") do |table|
      table.generated_id("id")
      table.string("title", null: false)
      table.bool("completed", null: false, default: false)
      table.int64("version", null: false, default: 0_i64)
    end
  end
end

migrations = LF::Data::MigrationSet.new(CreateTodos.new)
LF::Data::MigrationRunner.new(source).run(migrations)
```

## Task 1: Define Migration And MigrationSet

**Files**

- Create: `src/opal/data/migration.cr`
- Create: `src/opal/data/migration_set.cr`
- Modify: `src/opal/data.cr`
- Create: `spec/data/migration_set_spec.cr`

`Migration` requires `version`, `name`, and `up`. `MigrationSet` stores explicit
instances in declared order.

Validate before opening a DB transaction:

- version is positive;
- versions are unique;
- versions are strictly ascending;
- name is non-empty;
- migration instances are not nil or discovered globally.

Errors include conflicting version/name data.

## Task 2: Define Portable Schema Operations

**Files**

- Create: `src/opal/data/schema/operation.cr`
- Create: `src/opal/data/schema/table_builder.cr`
- Create: `src/opal/data/schema/index_definition.cr`
- Create: `spec/data/schema/table_builder_spec.cr`

Represent operations as typed values before rendering SQL. V1 types:

- generated Int64 ID;
- `string`, `text`, `bool`, `int32`, `int64`, `float64`, `timestamp`, `bytes`;
- nullability and literal defaults;
- primary key, foreign key, unique constraint;
- index with optional uniqueness;
- create/drop table;
- add/rename column;
- raw SQL.

Builder validates duplicate columns/constraints/index names, empty identifiers,
invalid defaults, and foreign keys referencing missing local columns.

No entity type is accepted by the schema DSL. This prevents mapping metadata
from becoming schema authority.

## Task 3: Add The Schema Renderer Contract

**Files**

- Create: `src/opal/data/schema/renderer.cr`
- Create: `src/opal/data/schema_editor.cr`
- Modify: `src/opal/data/dialect.cr`
- Create: `spec/data/schema/renderer_spec.cr`

`SchemaEditor` validates and sends typed operations to an abstract
`SchemaRenderer`; it does not contain `case dialect` branches.

Add a default dialect method:

```crystal
def schema_renderer(connection : DB::Connection) : SchemaRenderer
  raise UnsupportedSchemaOperationError.new(name, "schema migrations")
end
```

Concrete dialects override it when they support migrations. This keeps
MigrationRunner dependent on the base dialect only.

## Task 4: Render And Execute SQLite Schema Operations

**Files**

- Create: `src/opal/data/dialects/sqlite/schema_renderer.cr`
- Modify: `src/opal/data/dialects/sqlite.cr`
- Create: `spec/data/dialects/sqlite/schema_renderer_spec.cr`

Use dialect identifier quoting. Test exact SQL and resulting SQLite schema for
every operation.

SQLite capability policy:

- create/drop table and indexes are supported;
- add column is supported within SQLite constraints;
- rename column is supported;
- unsupported ALTER combinations fail before SQL;
- raw SQL executes exactly as supplied and is explicitly named in listener
  events.

`create_table(..., if_not_exists: true)` applies to the table and indexes emitted
by that create-table operation. It exists for idempotent infrastructure such as
the migration history table; ordinary migration DDL remains strict by default.

Never emulate unsupported destructive alteration by silently rebuilding a
table in v1.

## Task 5: Add Migration History

**Files**

- Create: `src/opal/data/migration_history.cr`
- Create: `spec/data/migration_history_spec.cr`

Create `_lf_migrations` with:

- `version INTEGER PRIMARY KEY`;
- `name TEXT NOT NULL`;
- `applied_at TEXT NOT NULL`.

History behavior:

- table creation is idempotent;
- applied rows load ordered by version;
- same version and same name is applied;
- same version and different name raises
  `MigrationHistoryMismatchError`;
- an applied version absent from the current set is retained and not reversed.

No source checksum is stored in v1.

History renders identifiers and placeholders through the abstract `Dialect`.
Its table DDL goes through `SchemaEditor`; Data core does not contain SQLite SQL.
History schema/select/insert statements use the datasource statement observer
when one is present, with a direct execution fast path when it is absent.

## Task 6: Implement MigrationRunner

**Files**

- Create: `src/opal/data/migration_runner.cr`
- Create: `spec/data/migration_runner_spec.cr`

Runner algorithm:

1. validate the complete MigrationSet;
2. ensure history table;
3. read applied migrations;
4. validate name matches;
5. for each pending migration, open one datasource transaction;
6. ask the DataSource dialect for its SchemaRenderer;
7. construct SchemaEditor on that renderer and transaction connection;
8. invoke `up`;
9. insert history row in the same transaction;
10. stop immediately on failure.

Test fresh run, repeated no-op, multiple pending versions, failure rollback,
history atomicity, empty set, migration throwing before SQL, and DB error
preservation.

`EntityManager#__lf_statement_observer` is a generic internal bridge from SQL
owned by Data extensions to the datasource listener dispatcher. It references
only `StatementCompletionEvent`; EntityManager does not depend on migrations or
schema rendering.

## Task 7: Test Concurrent Runners

Use two DataSources against one temporary SQLite file. Coordinate two fibers so
both observe a pending migration. The history primary key must prevent double
application. One runner may receive a typed concurrency/history error; neither
may leave a partial schema or duplicate history row.

Do not add process-global migration locks. Database constraints and
transactions remain the coordination mechanism.

The concurrency regression lives in
`spec/data/migration_runner_concurrency_spec.cr`. It uses a barrier inside
`Migration#up` so two runners have both observed the same version as pending
before either executes its side effect.

## Verification

```bash
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec \
  spec/data/migration_set_spec.cr \
  spec/data/schema/table_builder_spec.cr \
  spec/data/schema/renderer_spec.cr \
  spec/data/dialects/sqlite/schema_renderer_spec.cr \
  spec/data/migration_history_spec.cr \
  spec/data/migration_runner_spec.cr \
  spec/data/migration_runner_concurrency_spec.cr --no-color
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec --no-color
git diff --check
```

Commit by capability:

```text
feat(data): add portable schema migrations
feat(data): add transactional migration runner
```
