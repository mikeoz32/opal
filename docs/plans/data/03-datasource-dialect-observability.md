# Data 03: DataSource, Dialect, And Observability

> **For Codex:** REQUIRED SKILLS: `executing-plans`,
> `test-driven-development`, and `verification-before-completion`.

**Goal:** Implement explicit database ownership and block-based transactions,
plus the smallest dialect and observability contracts needed by later plans.

**Architecture:** `DataSource` delegates pool and transaction mechanics to
`crystal-db`. It creates a transaction-local manager through an internal
factory seam; Plan 05 replaces the placeholder with `EntityManager` without
changing the public transaction API.

**Prerequisite:** Plan 01 is merged. Plan 02 is not required.

---

## Public API

```crystal
source = LF::Data::DataSource.open(
  "sqlite3://./app.db",
  dialect: LF::Data::SQLiteDialect.new
)

source = LF::Data::DataSource.new(
  database,
  dialect: LF::Data::SQLiteDialect.new,
  owns_database: false
)

value = source.transaction do |manager|
  "block result"
end
```

`open` owns its database. Constructor injection borrows by default. `close` is
idempotent. A datasource has no default/global instance.

## Task 1: Add Error Types

**Files**

- Create: `src/opal/data/errors.cr`
- Modify: `src/opal/data.cr`
- Create: `spec/data/errors_spec.cr`

Add `LF::Data::Error < Exception` and the DataSource/manager errors required by
this plan:

- `ClosedDataSourceError`;
- `ClosedEntityManagerError`;
- `FailedEntityManagerError`.

Errors are catchable by class and expose operation/cause where relevant.
Driver errors are not wrapped in `LF::Data::Error`.

## Task 2: Define The Narrow Dialect Contract

**Files**

- Create: `src/opal/data/dialect.cr`
- Create: `src/opal/data/sqlite_dialect.cr`
- Create: `spec/data/sqlite_dialect_spec.cr`

Implement:

```crystal
abstract def quote_identifier(name : String) : String
abstract def placeholder(index : Int32) : String
abstract def append_limit_offset(io : IO, limit : Int32?, offset : Int32?) : Nil
abstract def generated_id(result : DB::ExecResult, type : T.class) : T forall T
abstract def transactional_ddl? : Bool
```

SQLite behavior:

- quote with double quotes and double embedded quote characters;
- reject empty/NUL-containing identifiers;
- always render `?` placeholders;
- render `LIMIT` before `OFFSET`, using `LIMIT -1` for offset-only SQLite;
- convert `last_insert_id` only to supported generated integer types;
- report transactional DDL support.

Do not add PostgreSQL placeholders, upsert, isolation, native JSON, or locking.

## Task 3: Add Listener Events

**Files**

- Create: `src/opal/data/listener.cr`
- Create: `spec/data/listener_spec.cr`

Define immutable event records for:

- transaction begin;
- transaction completion with commit/rollback outcome and elapsed time;
- statement completion with operation, optional entity name, SQL, elapsed time,
  rows affected, and exception.

Define a structural listener module with no-op default methods. DataSource
stores instances supplied through its constructor. Events do not contain bind
values.

Tests prove:

- listener order matches constructor order;
- no listener callback occurs for unregistered listeners;
- listener exceptions do not replace the application/DB error;
- statement events can be emitted later by manager/query code through one
  internal datasource-owned dispatcher.

## Task 4: Add The Internal Transaction Manager Seam

**Files**

- Create: `src/opal/data/transaction_manager.cr`
- Create: `spec/data/support/probe_transaction_manager.cr`

The temporary internal protocol exposes only:

```crystal
abstract def flush : Nil
abstract def close : Nil
```

DataSource receives an internal factory used by specs. Production construction
uses a minimal no-op implementation until Plan 05. This protocol is not
documented or exported as user API.

## Task 5: Implement DataSource Lifecycle

**Files**

- Create: `src/opal/data/data_source.cr`
- Create: `spec/data/data_source_spec.cr`

Write one failing spec per behavior:

1. borrowed database remains usable after datasource close;
2. owned database rejects queries after close;
3. repeated close is a no-op;
4. transaction returns the exact block result;
5. normal return calls manager flush then commits;
6. block exception skips flush, rolls back, and propagates unchanged;
7. flush exception rolls back and propagates unchanged;
8. manager closes before connection returns to pool;
9. transaction after datasource close raises typed error;
10. two fibers have different manager/connection lifetimes;
11. no transaction leaks after either success or failure.

Use `DB::Database#transaction`; do not manually emulate commit/rollback.

## Verification

```bash
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec \
  spec/data/errors_spec.cr \
  spec/data/sqlite_dialect_spec.cr \
  spec/data/listener_spec.cr \
  spec/data/data_source_spec.cr --no-color
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec --no-color
git diff --check
```

Review the diff for forbidden dependencies:

```bash
rg -n "LF::Application|LF::DI|LF::HTTP|YAML|sqlite3" src/opal/data*
```

Only `SQLiteDialect` naming is allowed; requiring the concrete driver is not.

Commit as:

```text
feat(data): add datasource transaction foundation
```
