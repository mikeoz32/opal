# Data 05: Typed Query And Bulk DML

> **For Codex:** REQUIRED SKILLS: `executing-plans`,
> `test-driven-development`, and `verification-before-completion`.

**Goal:** Add composable type-checked entity queries and explicit bulk writes
without method-name parsing, raw value interpolation, or implicit flush.

**Architecture:** Generated field descriptors validate Crystal values and dump
them through field converters. Runtime expression nodes represent only the
dynamic query shape. A dialect renderer produces SQL and ordered bind values.

**Prerequisite:** Plans 03 and 04 are merged.

---

## Target API

```crystal
open = Todo::Fields.completed.eq(false)
named = Todo::Fields.title.like("%opal%")

todos = em.query(Todo)
  .where(open.and(named))
  .order_by(Todo::Fields.id.desc)
  .limit(20)
  .offset(0)
  .to_a

em.update(Todo)
  .set(Todo::Fields.completed, true)
  .where(Todo::Fields.id.eq(id))
  .execute
```

## Task 1: Implement Typed Predicates

**Files**

- Modify: `src/opal/data/query/field.cr`
- Create: `src/opal/data/query/expression.cr`
- Create: `spec/data/query/field_compile_spec.cr`
- Create: `spec/data/query/expression_spec.cr`

Methods:

- `eq`, `ne`;
- `lt`, `lte`, `gt`, `gte` for ordered value types;
- `in(Enumerable(T))`;
- `is_nil`, `is_not_nil` only for nilable fields;
- `like` only for String fields;
- expression `and`, `or`, and `not`.

Compile fixtures prove wrong values, LIKE on non-string fields, and nil
predicates on non-nil fields fail compilation.

Expression nodes retain field reference, operator, and dumped `DB::Any` values.
They never contain pre-interpolated SQL.

## Task 2: Implement Dialect Rendering

**Files**

- Create: `src/opal/data/query/rendered_query.cr`
- Create: `src/opal/data/query/renderer.cr`
- Create: `spec/data/query/renderer_spec.cr`

`RenderedQuery` contains SQL and `Array(DB::Any)`. Test:

- every comparison operator;
- nested grouping;
- stable depth-first bind order;
- identifiers with quote characters;
- malicious values absent from SQL;
- null predicates have no bind;
- empty IN renders a false predicate;
- non-empty IN has one placeholder per value;
- converter dump is called exactly once per value.

## Task 3: Implement SELECT Builder

**Files**

- Create: `src/opal/data/query/select_query.cr`
- Modify: `src/opal/data/entity_manager.cr`
- Create: `spec/data/query/select_query_spec.cr`

Builder state is immutable or copy-on-write so a base query can be reused
without later calls changing it.

Support:

- repeated `where`, combined with AND;
- `order_by` with multiple typed fields;
- `limit` and `offset`;
- `to_a`;
- `first?`;
- `count`;
- `exists?`.

Reject negative limit/offset. `first?` applies limit one without mutating the
source builder. Count/exists ignore ordering and pagination only when explicitly
documented by their implementation tests; choose and lock one behavior before
production code. The selected v1 behavior is: preserve WHERE, ignore ordering,
limit, and offset for `count`; preserve WHERE and use dialect limit one for
`exists?`.

Entity SELECT always requests the full generated column list and registers rows
through the identity map. If an identity is already managed, return that object
without replacing its fields.

## Task 4: Prove Queries Never Flush

Add pending INSERT/UPDATE/DELETE, then run every terminal SELECT operation.
Assert no queued write SQL executes and query results reflect database state,
not pending in-memory state. An explicit `em.flush` changes that result.

This is a regression contract, not an implementation detail.

## Task 5: Implement Bulk UPDATE

**Files**

- Create: `src/opal/data/query/update_query.cr`
- Create: `spec/data/query/update_query_spec.cr`

Support repeated typed `set` and repeated WHERE. The last set for the same field
wins while retaining first field order. Reject:

- zero SET clauses;
- ID or version field assignment;
- wrong value type;
- execution when per-entity operations for that entity type are pending.

WHERE is optional by design; whole-table updates are explicit through a builder
with at least one SET.

After successful execution, mark every managed entity of that type Detached.
Return `DB::ExecResult#rows_affected`.

## Task 6: Implement Bulk DELETE

**Files**

- Create: `src/opal/data/query/delete_query.cr`
- Create: `spec/data/query/delete_query_spec.cr`

Support optional WHERE and return affected rows. Reject execution when queued
per-entity operations exist for that type. After success, detach all managed
entities of that type.

## Task 7: Add Raw SQL Escape-Hatch Contract

Expose the active `DB::Connection` as a read-only getter on EntityManager.
Document and test that:

- it is the transaction's connection;
- it cannot be accessed after manager close/failure;
- raw SQL errors preserve their DB type;
- framework does not attempt to infer which raw writes invalidate identity.

Add `em.clear(T)` to detach all managed entities of one type and reject pending
operations for that type. Documentation requires `clear` or abandoning the
manager after raw writes.

## Verification

```bash
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec spec/data/query --no-color
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec spec/data --no-color
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec --no-color
git diff --check
```

Review generated SQL and query counts for accidental auto-flush or N+1
metadata work.

Commit as:

```text
feat(data): add typed entity queries
feat(data): add typed bulk writes
```
