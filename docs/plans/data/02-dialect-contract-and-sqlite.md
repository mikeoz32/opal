# Data 02: Dialect Contract And SQLite Implementation

> **For Codex:** REQUIRED SKILLS: `executing-plans`,
> `test-driven-development`, and `verification-before-completion`.

**Goal:** Define a driver-independent, compile-time-specialized SQL dialect
contract and ship SQLite as the first optional concrete dialect without making
SQLite part of Data core.

**Architecture:** A concrete dialect implements generic methods whose final SQL
is specialized by Crystal for the static entity and query-shape types used by
the program. Plans contain final SQL and result semantics only. Entity/query
code supplies direct bind tuples at runtime. Drivers remain responsible for
connections, binding, execution, result conversion, statement preparation, and
prepared-statement caching.

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

## Task 1: Define Mapping Vocabulary And Immutable Statement Results

**Files**

- Create: `src/opal/data/mapping_annotations.cr`
- Create: `src/opal/data/sql/statement_plan.cr`
- Create: `src/opal/data/sql/insert_plan.cr`
- Create: `spec/data/sql/statement_plan_spec.cr`

Define the inert compile-time annotations needed by dialect specialization:

- `LF::Data::Table`;
- `LF::Data::Column`;
- `LF::Data::Id`;
- `LF::Data::Version`.

At this stage they store only declared options. They do not install methods,
register entity types, validate complete mapping, or require an `Entity`
module. Static dialect fixtures annotate ordinary classes. Plan 04 adds
`LF::Data::Entity`, full validation, hydration, bind extraction, and typed
fields without redefining the annotations.

Define:

```crystal
enum LF::Data::SQL::GeneratedKeySource
  None
  LastInsertId
  ReturningRow
end

record LF::Data::SQL::StatementPlan,
  sql : String

record LF::Data::SQL::InsertPlan,
  sql : String,
  generated_key_source : GeneratedKeySource,
  generated_column : String?
```

Plans contain final SQL and result interpretation only. They never contain:

- entity values;
- `Array(DB::Any)`;
- field indexes, symbols, or column lookup keys;
- `BindSlot` or any runtime bind-order description;
- prepared statement or connection objects.

Entity and query macros added by Plans 04 and 06 generate direct bind tuples in
the exact order required by the corresponding plan.

## Task 2: Define The Generic Dialect Contract

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

  abstract def find_plan(entity : T.class) : SQL::StatementPlan forall T
  abstract def insert_plan(entity : T.class) : SQL::InsertPlan forall T
  abstract def update_plan(entity : T.class) : SQL::StatementPlan forall T
  abstract def delete_plan(entity : T.class) : SQL::StatementPlan forall T

  abstract def supports?(capability : DialectCapability) : Bool
end
```

Plan 06 extends the same contract with generic SELECT and bulk-DML shape
methods. The receiver may be stored as `LF::Data::Dialect`; Crystal's virtual
generic dispatch still specializes the concrete implementation for `T`.
`DataSource` therefore does not become generic over a dialect type.

The generic methods are a compile-time boundary:

- the concrete implementation uses macros to inspect the static type;
- the returned SQL is a compile-time-produced string literal;
- execution does not quote identifiers, append placeholders, or use
  `String::Builder`;
- calling the same method for different concrete dialects produces independent
  SQL specializations.

Plan 02 uses small test-only annotated entity types to prove this mechanism.
The dialect macro reads the static type's instance variables and mapping
annotations directly. Plan 04 installs and validates the complete entity
contract over that same source of truth.

Initial capabilities describe execution-relevant differences:

- last-insert-ID generated keys;
- returning-row generated keys;
- transactional DDL;
- add column;
- rename column;
- foreign-key DDL.

Capabilities are a closed enum, not a mutable registry. Invalid identifiers
(empty or containing NUL) are rejected before dialect generation.

Do not add connection creation, URL parsing, type conversion, logging,
transactions, retries, isolation, application configuration, or a plan cache
to Dialect.

## Task 3: Add SQLite As An Optional Concrete Dialect

**Files**

- Create: `src/opal/data/dialects/sqlite.cr`
- Create: `spec/data/dialects/sqlite_spec.cr`
- Create: `spec/fixtures/data/sqlite_dialect_without_driver.cr`

SQLite behavior:

- `name` is `"sqlite"`;
- identifiers use double quotes and embedded quotes are doubled at compile
  time for static shapes;
- every placeholder is `?`, regardless of position;
- assigned-ID INSERT uses `GeneratedKeySource::None`;
- generated integer INSERT uses `GeneratedKeySource::LastInsertId`;
- INSERT does not append `RETURNING`;
- generated key is read later from `DB::ExecResult#last_insert_id`;
- transactional DDL, add column, rename column, and foreign keys report their
  explicit v1 capability values.

Test exact SELECT-by-ID, INSERT, UPDATE, DELETE, versioned UPDATE/DELETE,
reserved-word identifiers, quote-containing identifiers, and empty writable
column lists using static fixture types. Inspect macro expansion for at least
one fixture and assert that execution code contains a final SQL literal rather
than runtime SQL assembly.

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
implementation. It proves:

- the same static fixture type produces different SQL for different dialects;
- generic dispatch through an `LF::Data::Dialect` reference reaches the
  concrete specialization;
- operation plans represent both last-insert-ID and returning-row strategies;
- EntityManager can later stay independent of either strategy.

Do not ship PostgreSQL/MySQL namespaces, URL aliases, or incomplete production
dialects.

## Task 5: Lock Compile-Time Specialization Regressions

**Files**

- Create: `spec/data/dialects/specialization_spec.cr`
- Create: `spec/fixtures/data/dialect_virtual_generic_dispatch.cr`

Cover:

1. repeated calls for the same entity/dialect combination return identical SQL;
2. two entity shapes produce their own SQL literals;
3. SQLite and the returning probe produce different SQL from the same shape;
4. no static execution path allocates a bind-order array;
5. no Opal cache is needed to avoid SQL regeneration;
6. generic dispatch works through an abstract dialect reference;
7. the fixture passes `--no-codegen`.

Run the compile fixture on the minimum supported Crystal version, 1.18.2, in
CI. The local implementation environment may be newer, but the generic virtual
dispatch and macro specialization are release compatibility requirements.

Do not implement a `PlanKey`, `PlanCache`, or Opal-owned prepared-statement
cache. `crystal-db` already caches prepared statements per connection by SQL.

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

Schema commands are intentionally runtime-built because migration code is an
imperative DSL, not an entity query hot path. Do not reuse that renderer for
static CRUD/query generation.

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
rg -n "sqlite3|DB\\.open|LF::Application|LF::DI|YAML|PlanCache|BindSlot" \
  src/opal/data/dialect.cr \
  src/opal/data/sql \
  src/opal/data/dialects/sqlite.cr
```

No concrete driver, Application, DI, configuration, bind-slot traversal, or
framework plan cache is allowed.

Commit as:

```text
feat(data): add compile-time dialect foundation
feat(data): add sqlite dialect
```
