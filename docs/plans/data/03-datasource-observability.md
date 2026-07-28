# Data 03: DataSource And Observability

> **For Codex:** REQUIRED SKILLS: `executing-plans`,
> `test-driven-development`, and `verification-before-completion`.

**Goal:** Implement explicit database ownership, block-based transactions, and
instance-scoped observability on top of the dialect contract from Plan 02.

**Architecture:** `DataSource` delegates pool and transaction mechanics to
`crystal-db`. It creates a transaction-local manager through an internal
factory seam; Plan 05 replaces the placeholder with `EntityManager` without
changing the public transaction API.

**Prerequisite:** Plans 01 and 02 are merged. No Application work is required.

---

## Public API

```crystal
source = LF::Data::DataSource.open(
  "sqlite3://./app.db",
  dialect: LF::Data::Dialects::SQLite.new
)

source = LF::Data::DataSource.new(
  database,
  dialect: LF::Data::Dialects::SQLite.new,
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

## Task 2: Add Listener Events

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

## Task 3: Add The Internal Transaction Manager Seam

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

## Task 4: Implement DataSource Lifecycle

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

## Task 5: Add A Per-DataSource Static Plan Cache

**Files**

- Create: `src/opal/data/sql/plan_cache.cr`
- Create: `spec/data/sql/plan_cache_spec.cr`

DataSource owns one fiber-safe cache keyed by Plan 02's `SQL::PlanKey`.
`fetch(key) { compile }` compiles a missing static CRUD/find plan once and
reuses the same immutable plan across transactions and connections belonging to
that DataSource.

The cache:

- is never global or class-level;
- stores no bind values or entity instances;
- does not cache dynamic query expressions;
- is cleared when the DataSource closes;
- does not cache a failed compilation;
- compiles once under concurrent fiber access.

EntityManager receives access to this cache through its constructor in Plan 05.

## Verification

```bash
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec \
  spec/data/errors_spec.cr \
  spec/data/listener_spec.cr \
  spec/data/sql/plan_cache_spec.cr \
  spec/data/data_source_spec.cr --no-color
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec --no-color
git diff --check
```

Review the diff for forbidden dependencies:

```bash
rg -n "LF::Application|LF::DI|LF::HTTP|YAML|sqlite3" \
  src/opal/data/data_source.cr \
  src/opal/data/listener.cr \
  src/opal/data/errors.cr
```

DataSource may reference only the abstract `LF::Data::Dialect`, never
`LF::Data::Dialects::SQLite` or the concrete driver.

Commit as:

```text
feat(data): add datasource transaction foundation
```
