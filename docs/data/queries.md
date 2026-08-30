# Data Queries

Static query shapes are type-checked and compiled for the concrete entity and
dialect:

```crystal
fields = Todo::Fields

todos = manager.query(Todo)
  .where(fields.completed.eq(false))
  .order_by(fields.id.desc)
  .limit(20)
  .to_a
```

Fields cannot be mixed across entities. Value types, NULL predicates, ordering,
limit/offset shape, and bulk assignments are checked at compile time. Static
CRUD and query execution pass generated tuples directly and do not render SQL
or walk bind metadata at runtime.

Bulk update and delete remain explicit:

```crystal
manager.update(Todo)
  .set(fields.completed, true)
  .where(fields.id.eq(id))
  .execute
```

Arbitrary runtime filters use `DynamicQuery`; they are never silently routed
through the static API. Neither static nor dynamic SELECT flushes pending
writes.

Opal owns no prepared-statement cache. SQL executes through the checked-out
`DB::Connection`, and `crystal-db` owns connection-local preparation and
caching.

Inside a transaction, `manager.repository(Entity)` provides typed `find`,
`find_by`, `count`, `exists?`, entity writes, typed bulk builders, and
deterministic one-based pagination over these same plans. Pagination accepts a
composed ordered static query, so repeated predicates and stable multi-column
ordering are preserved. Its `query` and `dynamic_query` methods expose the
original builders without changing their behavior. See
[transactions and repositories](transactions-and-repositories.md) for the
lifecycle and pagination contract.
