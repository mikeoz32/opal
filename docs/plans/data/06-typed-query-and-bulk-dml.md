# Data 06: Typed Query And Bulk DML

> **For Codex:** REQUIRED SKILLS: `executing-plans`,
> `test-driven-development`, and `verification-before-completion`.

**Goal:** Add composable type-checked entity queries and explicit bulk writes
whose static shapes become dialect SQL at compile time, without method-name
parsing, raw value interpolation, or implicit flush.

**Architecture:** Generated field marker types and generic expression structs
encode identifiers, operators, grouping, ordering, pagination presence, and
placeholder count in the Crystal type. Expression objects retain only runtime
values. Plan 02's shared static plan compiler is extended to specialize final
SQL for `Entity + ConcreteDialect + QueryShape`, using the concrete dialect's
static policy; generated query code supplies a direct bind tuple. An explicit
`DynamicQuery` handles structures that cannot be known at compile time.

**Prerequisite:** Plans 04 and 05 are merged.

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

The SELECT shape above is conceptually:

```crystal
SelectQuery(
  Todo,
  And(Eq(Todo::Fields::Completed), Like(Todo::Fields::Title)),
  OrderBy(Todo::Fields::Id, Desc),
  WithLimit,
  WithOffset
)
```

These names describe the required type information, not mandatory public
constructor syntax.

## Task 1: Implement Type-Level Predicates

**Files**

- Modify: `src/opal/data/query/field.cr`
- Create: `src/opal/data/query/expression.cr`
- Create: `spec/data/query/field_compile_spec.cr`
- Create: `spec/data/query/expression_spec.cr`

Methods:

- `eq`, `ne`;
- `lt`, `lte`, `gt`, `gte` for ordered value types;
- fixed-arity `in(Tuple)`;
- `is_nil`, `is_not_nil` only for nilable fields;
- `like` only for String fields;
- expression `and`, `or`, and `not`.

Each expression type encodes its field marker, closed operator, and child shape.
Its instance stores only converted runtime values. Examples:

```crystal
Eq(Todo::Fields::Completed)
And(Eq(Todo::Fields::Completed), Like(Todo::Fields::Title))
In(Todo::Fields::Id, Tuple(Int64, Int64))
```

Compile fixtures prove wrong values, LIKE on non-string fields, nil predicates
on non-nil fields, and a runtime-arity `IN` expression passed to static
`SelectQuery#where` fail compilation.

Generated `__lf_args` methods return typed tuples in stable depth-first order.
No expression contains pre-interpolated SQL, field-name strings used for
runtime lookup, or `Array(DB::Any)`.

An empty Tuple is a valid static `IN` shape and emits a dialect false
expression with no binds.

## Task 2: Extend Dialect With Static Query Plans

**Files**

- Modify: `src/opal/data/dialect.cr`
- Modify: `src/opal/data/sql/static_plan_compiler.cr`
- Modify: `src/opal/data/dialects/sqlite.cr`
- Create: `spec/data/query/static_sql_spec.cr`
- Modify: `spec/data/dialects/returning_probe_spec.cr`

Add generic plan methods:

```crystal
abstract def select_plan(
  entity : T.class,
  shape : S.class
) : SQL::StatementPlan forall T, S

abstract def update_plan(
  entity : T.class,
  shape : S.class
) : SQL::StatementPlan forall T, S

abstract def delete_plan(
  entity : T.class,
  shape : S.class
) : SQL::StatementPlan forall T, S
```

Use distinct method names if required to avoid overload ambiguity with
entity-instance UPDATE/DELETE plans, but preserve this separation in the type
contract.

The shared compiler's installed generic methods inspect `T` and `S`, then apply
the including dialect's static policy to emit a complete SQL literal. SQLite
tests cover:

- every comparison operator;
- nested grouping and explicit parentheses;
- stable depth-first placeholder order;
- quoted identifiers;
- `IS NULL`/`IS NOT NULL` with no bind;
- fixed-arity and empty `IN`;
- multiple typed ordering clauses;
- bound limit and offset;
- offset-only SQLite syntax;
- SELECT, count, exists, bulk UPDATE, and bulk DELETE shapes.

For example:

```sql
SELECT "id", "title", "completed"
FROM "todo"
WHERE "completed" = ?
ORDER BY "id" DESC
LIMIT ? OFFSET ?
```

The execution path must not invoke `quote_identifier`, `placeholder`,
`String::Builder`, or a query renderer. Inspect one macro expansion and add a
regression fixture that fails if static plans depend on runtime expression
instances.

## Task 3: Implement The Static SELECT Builder

**Files**

- Create: `src/opal/data/query/select_query.cr`
- Modify: `src/opal/data/entity_manager.cr`
- Create: `spec/data/query/select_query_spec.cr`

Every builder operation returns a new static type carrying the new shape and an
object carrying only values. The builder is immutable/copy-on-write so a base
query can be reused without later calls changing it.

Support:

- repeated `where`, combined with AND;
- `order_by` with multiple typed fields;
- `limit` and `offset`;
- `to_a`;
- `first?`;
- `count`;
- `exists?`.

Reject negative limit/offset before execution. `first?` adds a static limit-one
shape without mutating the source builder. The v1 terminal semantics are:

- `count` preserves WHERE and ignores ordering, limit, and offset;
- `exists?` preserves WHERE, ignores ordering/pagination, and uses a static
  dialect limit-one shape.

Execution does:

```crystal
plan = @dialect.select_plan(T, query.class)
connection.query(plan.sql, *query.__lf_args)
```

Generated argument order includes predicate values, then pagination values in
the exact order emitted by the dialect. Values remain parameters; identifiers,
operators, ordering direction, and placeholder count are compile-time shape.
`crystal-db` prepares and caches identical SQL per connection.

Entity SELECT always requests the full generated column list and registers rows
through the identity map. If an identity is already managed, return that object
without replacing its fields.

## Task 4: Cover Runtime Branches Without Runtime Rendering

**Files**

- Create: `spec/data/query/query_shape_union_spec.cr`
- Create: `spec/fixtures/data/query_shape_union.cr`

A runtime condition may create a union of static query types:

```crystal
query = if completed.nil?
          em.query(Todo)
        else
          em.query(Todo).where(Todo::Fields.completed.eq(completed))
        end
```

Crystal must compile one SQL specialization per union member. Test:

- both branches execute their expected SQL;
- each branch has the correct bind tuple;
- neither branch renders SQL at runtime;
- adding limit/offset values does not create a specialization per value;
- adding a structurally different clause does create a different shape.

Document the tradeoff: `N` independent optional predicates can create up to
`2^N` static shapes. Applications with large arbitrary filter sets must use the
explicit dynamic API instead of forcing a large union.

## Task 5: Add Explicit DynamicQuery

**Files**

- Create: `src/opal/data/query/dynamic_query.cr`
- Create: `src/opal/data/query/rendered_query.cr`
- Create: `src/opal/data/query/dynamic_renderer.cr`
- Create: `spec/data/query/dynamic_query_spec.cr`

Entry point:

```crystal
query = em.dynamic_query(Todo)
filters.each do |filter|
  query.where(filter)
end
query.limit(limit).offset(offset).to_a
```

`DynamicQuery` is explicit and never selected automatically by `query(T)`.
It supports runtime collections of typed dynamic expressions and a field
`in(Array(T))` overload whose result is accepted only by dynamic builders. Its
renderer returns SQL plus `Array(DB::Any)`.

Retain all safety guarantees:

- fields come from generated descriptors;
- operators and ordering are closed framework enums/types;
- identifiers are validated and quoted by the dialect;
- values, limit, and offset always use placeholders;
- converter dump runs exactly once per value;
- empty runtime `IN` renders a false predicate;
- user values never enter SQL text.

`DynamicQuery` may produce different SQL strings for different structures.
Opal does not cache these strings or `DB::Statement` objects. Execution still
uses `DB::Connection#query/#exec`, so `crystal-db` may reuse a prepared
statement when an identical SQL string recurs on the same connection.

Do not provide raw column names, arbitrary operators, or a silent fallback from
static query types.

## Task 6: Prove Queries Never Flush

Add pending INSERT/UPDATE/DELETE, then run every terminal SELECT operation for
both static and dynamic builders. Assert no queued write SQL executes and query
results reflect database state, not pending in-memory state. An explicit
`em.flush` changes that result.

This is a regression contract, not an implementation detail.

## Task 7: Implement Static Bulk UPDATE

**Files**

- Create: `src/opal/data/query/update_query.cr`
- Create: `spec/data/query/update_query_spec.cr`

Encode SET fields and predicates in the builder type; store only assigned and
predicate values. Support repeated typed `set` and repeated WHERE. The last set
for the same field wins while retaining first field order. Reject:

- zero SET clauses;
- ID or version field assignment;
- wrong value type;
- execution when per-entity operations for that entity type are pending.

WHERE is optional by design; whole-table updates are explicit through a builder
with at least one SET. The dialect specializes final SQL from the static shape,
and `__lf_args` returns SET values followed by predicate values.

After successful execution, mark every managed entity of that type Detached.
Return `DB::ExecResult#rows_affected`.

An application needing a runtime-selected SET list must opt into a dynamic bulk
API. Do not add that API in v1 unless a concrete example requires it.

## Task 8: Implement Static Bulk DELETE

**Files**

- Create: `src/opal/data/query/delete_query.cr`
- Create: `spec/data/query/delete_query_spec.cr`

Encode the optional WHERE expression in the builder type and return affected
rows. Reject execution when queued per-entity operations exist for that type.
After success, detach all managed entities of that type.

## Task 9: Add Raw SQL Escape-Hatch Contract

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

Architecture audit:

```bash
rg -n "PlanCache|PlanKey|BindSlot|DB::Statement" src/opal/data
```

No Opal plan cache, bind-slot traversal, or retained prepared statement is
allowed. Review generated SQL and query counts for accidental auto-flush,
runtime SQL rendering on the static path, or N+1 metadata work.

Commit as:

```text
feat(data): add compile-time typed entity queries
feat(data): add explicit dynamic queries
feat(data): add typed bulk writes
```
