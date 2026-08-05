# Data Correctness Hardening

## Goal

Address the correctness findings from the Data layer review without moving
responsibilities into DI or Application. The implementation remains Crystal
native, keeps SQL plans compile-time generated where the current design allows
it, and preserves the existing transaction-local EntityManager contract.

## Architecture

- `Dialect` owns connection initialization and migration capability policy.
- `DataSource` applies dialect connection setup on every checked-out
  transaction connection and closes an owned database if setup fails.
- Query fields use compile-time name resolution and explicit NULL predicates.
- Migration execution uses immutable descriptors captured after validation.
- Migration history is forward-only, but an applied version unknown to the
  current executable refuses startup instead of being silently accepted.
- A concurrent migration loser reconciles against committed history; it does
  not rerun the migration body.
- EntityManager rollback mutation behavior remains an explicit documented
  contract and is covered by an integration test.

## Implementation Tasks

1. Add SQLite connection initialization, verify foreign-key enforcement, and
   test invalid foreign-key writes.
2. Add nullable `eq(nil)`/`ne(nil)` semantics, reject invalid NULL ordering and
   `IN` values, and cover static, dynamic, and compile-error paths.
3. Snapshot migration identity into `PlannedMigration`, record snapshots at the
   execution boundary, and reject unknown applied versions.
4. Reconcile concurrent migration losers from history and reject pending
   migrations on dialects without transactional DDL.
5. Make `limit(0).first?` return `nil` for static and dynamic queries.
6. Strengthen compile-time field identity with two independent hash keys while
   preserving the existing static Field descriptor API.
7. Add a rollback mutation integration test and document that entities from a
   failed transaction must be discarded.
8. Run the focused Data suite, the full suite, and an independent
   `gpt-5.6-terra` review before considering the work ready.

## Verification

```sh
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec spec/data --no-color --no-debug
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec --no-color --no-debug
```

Expected result: all existing tests remain green, and the new tests exercise
each review regression directly.
