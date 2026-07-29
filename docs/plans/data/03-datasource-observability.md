# Data 03: DataSource And Observability

> **For Codex:** REQUIRED SKILLS: `executing-plans`,
> `test-driven-development`, and `verification-before-completion`.

**Goal:** Implement explicit database ownership, block-based transactions, and
instance-scoped observability on top of the dialect contract from Plan 02.

**Architecture:** `DataSource` delegates pool and transaction mechanics to
`crystal-db`. It creates a transaction-local `EntityManager` through a
protected factory seam. This plan installs only the manager lifecycle contract;
Plan 05 adds persistence behavior to the same public type without changing the
transaction block API. `DataSource` stores only an abstract dialect reference
and does not own SQL-plan or prepared-statement caches.

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

## Task 3: Add The EntityManager Lifecycle Shell

**Files**

- Create: `src/opal/data/entity_manager.cr`
- Create: `spec/data/support/probe_entity_manager.cr`

Install the public transaction-local type that Plan 05 will extend. At this
stage it exposes only lifecycle behavior:

```crystal
class LF::Data::EntityManager
  def flush : Nil
  def close : Nil
end
```

The manager receives the checked-out `DB::Connection`, the abstract dialect
reference, and the datasource-owned event dispatcher. `DataSource` exposes a
protected factory method that specs can override with a probe subclass.
Production construction uses the minimal no-op lifecycle implementation until
Plan 05.

Do not introduce a separate `TransactionManager` abstraction. If the
transaction method yielded that protocol, Crystal would statically type the
block parameter as `TransactionManager`, and adding persistence methods to
`EntityManager` in Plan 05 would require changing the public API.

## Task 4: Implement DataSource Lifecycle

**Files**

- Create: `src/opal/data/data_source.cr`
- Create: `spec/data/data_source_spec.cr`

Write one failing spec per behavior:

1. borrowed database remains usable after datasource close;
2. owned database has its pooled connections closed and the datasource rejects
   further transactions;
3. repeated close is a no-op;
4. transaction returns the exact block result;
5. normal return calls manager flush, commits, then closes the manager;
6. block exception skips flush, rolls back, and propagates unchanged;
7. flush exception rolls back and propagates unchanged;
8. manager closes after commit/rollback and before connection returns to pool;
9. transaction after datasource close raises typed error;
10. two fibers have different manager/connection lifetimes;
11. no transaction leaks after either success or failure.

Use `DB::Database#using_connection` and `DB::Connection#transaction`.
`crystal-db` remains solely responsible for begin, commit, rollback, and
connection release. The explicit connection scope is required because
`DB::Database#transaction` returns the connection to the pool before
`DataSource` can close the manager.

## Task 5: Verify Statement-Preparation Ownership

**Files**

- Modify: `spec/data/data_source_spec.cr`

Prove the ownership boundary rather than adding another cache:

- DataSource stores the supplied `LF::Data::Dialect` reference;
- each EntityManager receives that same reference;
- DataSource contains no plan cache or statement cache;
- SQL execution goes through the checked-out `DB::Connection`;
- repeated identical SQL remains eligible for `crystal-db`'s per-connection
  prepared-statement cache;
- closing DataSource closes only resources described by its database ownership
  mode.

Do not retain `DB::Statement` instances. Their validity and cache lifetime
belong to the connection and driver.

## Verification

```bash
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec \
  spec/data/errors_spec.cr \
  spec/data/listener_spec.cr \
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
`LF::Data::Dialects::SQLite` or the concrete driver. It must not define a plan
cache or retain prepared statements.

Commit as:

```text
feat(data): add datasource transaction foundation
```
