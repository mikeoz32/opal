# Data 07: Optimistic Locking

> **For Codex:** REQUIRED SKILLS: `executing-plans`,
> `test-driven-development`, `systematic-debugging`, and
> `verification-before-completion`.

**Goal:** Detect concurrent updates and deletes through an optional generated
version field without introducing snapshots or automatic persistence.

**Architecture:** Mapping identifies one immutable application-facing `Int64`
version. EntityManager stores the expected loaded version in managed state and
uses compare-and-increment SQL during explicit flush.

**Prerequisite:** Plans 04 and 05 are merged. Plan 06 is optional.

---

## Implementation Progress

Tasks 1-5 are implemented:

- entity compilation accepts at most one immutable, non-ignored, converter-free
  `Int64` version field with a numeric zero ivar default;
- ID/version overlap, multiple, nilable, writable, ignored, converted,
  missing-default, and non-zero-default versions fail compilation;
- INSERT binds the initial zero version, while UPDATE and DELETE bind the
  manager-owned expected version directly after their existing arguments;
- successful UPDATE advances manager and entity versions only after SQL
  succeeds; stale UPDATE/DELETE raises typed `OptimisticLockError` and makes the
  manager terminal through the existing flush failure path;
- file-backed SQLite tests use two simultaneously alive EntityManagers on
  separate connections and autocommit statement transactions to exercise a
  real stale compare-and-set. Holding the second SQLite read transaction open
  across the first commit is intentionally not used: SQLite rejects that
  snapshot-to-writer upgrade with `database is locked` before row-count-based
  optimistic detection can run, and Opal preserves that driver error;
- explicit-flush regressions cover repeated batches, operation coalescing,
  stop-on-stale behavior, and the in-memory rollback caveat.

---

## Entity Contract

```crystal
class Todo
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  property title : String

  @[LF::Data::Version]
  getter version : Int64 = 0
end
```

The version field has no public setter. New entities start at zero. Hydration
restores the stored value through generated internal code.

## Task 1: Lock Compile-Time Version Rules

**Files**

- Modify: `spec/data/entity_compile_spec.cr`
- Add fixtures under: `spec/fixtures/data/entities/`

Verify:

- zero version fields remains valid;
- one `Int64` getter with default zero is valid;
- multiple version fields fail;
- nilable/non-Int64 version fails;
- public setter fails;
- ID and version cannot be the same field;
- ignored version fails.

Do not support timestamps, UUIDs, driver-specific row versions, or custom
version converters in v1.

## Task 2: Generate Version-Aware UPDATE

**Files**

- Modify: `src/opal/data/entity.cr`
- Modify: `src/opal/data/entity_manager.cr`
- Create: `spec/data/optimistic_update_spec.cr`

Plan 02's shared static compiler already emits the final SQL shape:

```sql
UPDATE "todo"
SET "title" = ?, "version" = "version" + 1
WHERE "id" = ? AND "version" = ?
```

This plan connects that shape to EntityManager execution and generated bind
tuples. Bind the expected version from manager state, not by re-reading a
user-mutated field. The generated UPDATE bind tuple contains writable field
values, ID, and the manager-supplied expected version in dialect placeholder
order; it does not use runtime bind metadata. Exactly one affected row is
success. On success:

1. update the manager's expected version;
2. write the incremented version to the entity;
3. complete the queued UPDATE.

On zero rows:

1. raise `LF::Data::OptimisticLockError`;
2. expose entity type, ID, expected version, and operation;
3. mark manager failed;
4. leave in-memory version unchanged;
5. let DataSource roll back.

## Task 3: Generate Version-Aware DELETE

**Files**

- Create: `spec/data/optimistic_delete_spec.cr`

DELETE predicates on ID and expected version. Its generated tuple contains
those two values directly. One row detaches the entity. Zero rows follows the
same stale-error and manager-failure rules as UPDATE.

## Task 4: Test Real Concurrency

**Files**

- Create: `spec/data/optimistic_concurrency_spec.cr`

Use a temporary file-backed SQLite database and two separate EntityManagers on
separate connections:

1. both load version zero;
2. first updates and commits version one;
3. second update fails stale and rolls back;
4. a fresh manager observes first writer's data/version;
5. repeat with stale delete;
6. non-versioned entities retain existing row-count behavior.

Do not simulate this only by manually changing the version column in the same
manager. For SQLite, use independent autocommit statement transactions so both
managers can load version zero before the first write. An overlapping stale
SQLite read transaction cannot be upgraded after another writer commits and
correctly remains a native `database is locked` driver case rather than an
`OptimisticLockError`.

## Task 5: Check Explicit Flush Edge Cases

Test:

- two successful updates separated by explicit flush advance twice;
- repeated `persist` before one flush advances once;
- UPDATE followed by DELETE before flush executes only versioned DELETE;
- failed stale flush prevents later queued operations;
- rollback caused after a successful explicit flush requires discarding the
  entity even though its in-memory version advanced.

Document the final rollback caveat in the transaction guide: Opal cannot undo
arbitrary in-memory object mutation.

## Verification

```bash
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec \
  spec/data/optimistic_update_spec.cr \
  spec/data/optimistic_delete_spec.cr \
  spec/data/optimistic_concurrency_spec.cr --no-color
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec spec/data --no-color
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec --no-color
git diff --check
```

Commit as:

```text
feat(data): add optimistic entity locking
```
