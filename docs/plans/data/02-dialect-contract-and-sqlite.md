# Data 02: Dialect Contract And SQLite Implementation

> **For Codex:** REQUIRED SKILLS: `executing-plans`,
> `test-driven-development`, and `verification-before-completion`.

**Goal:** Define a driver-independent SQL dialect contract and ship SQLite as
the first optional concrete dialect without making SQLite part of Data core.

**Architecture:** Compile-time entity metadata produces dialect-neutral
operation templates. A concrete dialect compiles static templates into cached
statement plans and renders dynamic query expressions. Drivers remain
responsible for connections, value binding, execution, and result conversion.

**Prerequisite:** Plan 01 is merged.

---

## Package And Naming Contract

Core entrypoint:

```crystal
require "opal/data"
```

SQLite dialect entrypoint:

```crystal
require "opal/data/dialects/sqlite"
```

SQLite driver remains separate:

```crystal
require "sqlite3"
```

Public types:

```crystal
abstract class LF::Data::Dialect
class LF::Data::Dialects::SQLite < LF::Data::Dialect
```

`opal/data` must not require a concrete dialect. The SQLite dialect must not
require or register the SQLite driver.

## Task 1: Define Dialect-Neutral SQL Operations

**Files**

- Create: `src/opal/data/sql/operation.cr`
- Create: `src/opal/data/sql/statement_plan.cr`
- Create: `src/opal/data/sql/insert_plan.cr`
- Create: `spec/data/sql/operation_spec.cr`

Define immutable operation templates for:

- find/select of a complete entity by ID;
- INSERT with ordered writable columns and optional generated key column;
- UPDATE with ordered assignments plus ID and optional version predicates;
- DELETE with ID and optional version predicate.

Templates contain identifiers, bind slots, and generated-key metadata. They do
not contain quoted SQL or actual bind values.

Define:

```crystal
enum LF::Data::SQL::GeneratedKeySource
  None
  LastInsertId
  ReturningRow
end

record LF::Data::SQL::StatementPlan,
  sql : String,
  bind_order : Array(BindSlot)

record LF::Data::SQL::InsertPlan,
  sql : String,
  bind_order : Array(BindSlot),
  generated_key_source : GeneratedKeySource,
  generated_column : String?
```

`BindSlot` contains a compile-time field index and a closed `BindRole`
(`Field`, `Id`, or `Version`). Entity-generated code reads a slot by index
through generated case branches. Do not use symbols, column strings, or a
runtime metadata hash to retrieve entity values.

Tests prove templates are immutable, preserve field order, and cannot carry
runtime entity values.

## Task 2: Define Base Dialect And Capabilities

**Files**

- Create: `src/opal/data/dialect.cr`
- Create: `src/opal/data/dialect_capability.cr`
- Modify: `src/opal/data.cr`
- Create: `spec/data/dialect_spec.cr`

Base contract:

```crystal
abstract class LF::Data::Dialect
  abstract def name : String
  abstract def quote_identifier(identifier : String) : String
  abstract def placeholder(position : Int32) : String

  abstract def compile_select(
    operation : SQL::SelectOperation
  ) : SQL::StatementPlan

  abstract def compile_insert(
    operation : SQL::InsertOperation
  ) : SQL::InsertPlan

  abstract def compile_update(
    operation : SQL::UpdateOperation
  ) : SQL::StatementPlan

  abstract def compile_delete(
    operation : SQL::DeleteOperation
  ) : SQL::StatementPlan

  abstract def append_pagination(
    io : IO,
    limit : Int32?,
    offset : Int32?
  ) : Nil

  abstract def supports?(capability : DialectCapability) : Bool
end
```

Initial capabilities describe execution-relevant differences:

- last-insert-ID generated keys;
- returning-row generated keys;
- transactional DDL;
- add column;
- rename column;
- foreign-key DDL.

Capabilities are a closed enum, not a mutable registry. Invalid identifiers
(empty or containing NUL) are rejected before dialect rendering.

Do not add connection creation, URL parsing, type conversion, logging,
transactions, retries, isolation, or application configuration to Dialect.

## Task 3: Add SQLite As An Optional Concrete Dialect

**Files**

- Create: `src/opal/data/dialects/sqlite.cr`
- Create: `spec/data/dialects/sqlite_spec.cr`
- Create: `spec/fixtures/data/sqlite_dialect_without_driver.cr`

SQLite behavior:

- `name` is `"sqlite"`;
- identifiers use double quotes and embedded quotes are doubled;
- every placeholder is `?`, regardless of position;
- offset-only pagination renders `LIMIT -1 OFFSET n`;
- assigned-ID INSERT uses `GeneratedKeySource::None`;
- generated integer INSERT uses `GeneratedKeySource::LastInsertId`;
- INSERT does not append `RETURNING`;
- generated key is read from `DB::ExecResult#last_insert_id`;
- transactional DDL, add column, rename column, and foreign keys report their
  explicit v1 capability values.

Test exact SELECT, INSERT, UPDATE, DELETE, versioned UPDATE/DELETE, pagination,
reserved-word identifiers, quote-containing identifiers, and empty column
lists.

The compile fixture requires `opal/data/dialects/sqlite` without `sqlite3` and
must pass `--no-codegen`.

## Task 4: Prove The Base Contract Does Not Assume SQLite

**Files**

- Create: `spec/data/dialects/returning_probe_spec.cr`

Implement a test-only dialect using numbered `$1`, `$2` placeholders and:

```sql
INSERT ... RETURNING "id"
```

with `GeneratedKeySource::ReturningRow`. This is not a PostgreSQL
implementation. It proves operation plans and later EntityManager execution can
represent both last-insert-ID and returning-row strategies.

Do not ship PostgreSQL/MySQL namespaces, URL aliases, or incomplete production
dialects.

## Task 5: Define Static Statement-Plan Cache Keys

**Files**

- Create: `src/opal/data/sql/plan_key.cr`
- Create: `spec/data/sql/plan_key_spec.cr`

The key contains:

- concrete dialect name;
- entity type name;
- operation kind;
- versioned/non-versioned shape.

It contains no entity ID, field value, query predicate, connection, or global
state. Plan 03 stores plans per DataSource; this plan defines only stable value
semantics.

## Task 6: Reserve The Schema-Dialect Boundary

**Files**

- Create: `src/opal/data/schema/capability.cr`
- Create: `docs/data/dialects.md` only if user documentation is being published
  incrementally; otherwise defer the guide to Plan 11.

Record the implementation rule used by Plan 08:

- schema operations are typed and dialect-neutral;
- schema rendering is a separate `SchemaRenderer` collaborator;
- each concrete dialect supplies its own renderer;
- MigrationRunner obtains the renderer from its DataSource dialect;
- unsupported operations fail before partial execution.

Do not implement the migration DSL or renderer in this plan. Plan 08 adds the
base renderer contract and `Dialects::SQLite::SchemaRenderer` together so
neither lands as a non-functional placeholder.

## Verification

```bash
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec \
  spec/data/dialect_spec.cr \
  spec/data/sql \
  spec/data/dialects --no-color
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec --no-color
git diff --check
```

Boundary audit:

```bash
rg -n "sqlite3|DB\\.open|LF::Application|LF::DI|YAML" \
  src/opal/data/dialect.cr \
  src/opal/data/sql \
  src/opal/data/dialects/sqlite.cr
```

No concrete driver, Application, DI, or configuration reference is allowed.

Commit as:

```text
feat(data): define database dialect contract
feat(data): add sqlite dialect
```

Stop for dialect API review before DataSource or entity mapping begins.
