# Transactions And Repositories

Application services own transaction boundaries. Repositories are stateless
and accept the active manager explicitly:

```crystal
class TodoRepository
  def find(manager : LF::Data::EntityManager, id : Int64) : Todo?
    manager.repository(Todo).find(id)
  end

  def delete(manager : LF::Data::EntityManager, id : Int64) : Bool
    manager.repository(Todo).delete(id)
  end
end

class TodoService
  def initialize(
    @source : LF::Data::DataSource,
    @todos : TodoRepository,
    @audits : AuditRepository,
  )
  end

  def rename(id : Int64, title : String) : Todo?
    @source.transaction do |manager|
      todo = @todos.find(manager, id)
      next unless todo
      todo.title = title
      manager.persist(todo)
      @audits.record(manager, id, "renamed")
      todo
    end
  end
end
```

Passing one manager lets several repositories participate in one atomic unit
without fiber-local or global state. Returned entities are detached from the
closed manager and cannot be scheduled in another manager without loading the
managed instance there first.

For common reads, the same manager can create an optional typed facade:

```crystal
source.transaction do |manager|
  todos = manager.repository(Todo)

  todo = todos.find(42_i64)
  first_open = todos.find_by(Todo::Fields.completed.eq(false))
  open_count = todos.count(Todo::Fields.completed.eq(false))
  any_open = todos.exists?(Todo::Fields.completed.eq(false))

  selection = todos.query
    .where(Todo::Fields.completed.eq(false))
    .order_by(Todo::Fields.created_at.desc)
    .order_by(Todo::Fields.id.desc)
  page = todos.page(
    selection,
    number: 2,
    size: 20
  )
end
```

`manager.repository(Todo)` infers both the entity and its exact lookup ID type.
For a generated `Int64?` entity ID, `find` accepts `Int64`, not `Int64?` or a
different integer type. `find_by` returns the first matching row; use the
facade's `query` or `dynamic_query` when ordering or runtime query composition
is required. `persist`, `remove`, and delete-by-ID bind writes to the same
entity type. `update` and `delete_all` expose the existing typed bulk builders:

```crystal
todos.persist(Todo.new("ship it"))
todos.delete(id)

todos.update
  .set(Todo::Fields.completed, true)
  .where(Todo::Fields.id.eq(id))
  .execute

todos.delete_all
  .where(Todo::Fields.completed.eq(true))
  .execute
```

Repository writes retain normal Unit of Work semantics. `persist`, `remove`,
and delete-by-ID remain queued until explicit or transaction-completion flush;
bulk builders execute immediately under their existing pending-operation rules.
`flush` stays on `EntityManager` because it coordinates all entity types and
repositories in the transaction.

Pages are one-based and require positive page numbers and sizes. An explicit
ordering is mandatory so repeated page requests have a caller-defined order.
Passing a composed static query preserves all predicates and supports repeated
`order_by` calls for a stable tie-breaker. The query must not already have a
limit or offset because the repository owns those values for the page.
It must also come from the same manager as the repository; mixing transaction
contexts raises `RepositoryQueryOwnershipError` before executing SQL.
Each page performs one `count` and one existing typed SELECT, returns an empty
`items` array when the requested page is outside the result, and reports zero
`total_pages` for an empty result set. `first?`, `last?`, `has_previous?`, and
`has_next?` describe navigation without additional SQL.

The facade is bound to the manager that created it. It cannot be constructed
from a `DataSource`, open a transaction, or outlive the transaction block; a
call after closure raises `ClosedEntityManagerError`. Its methods delegate to
the existing find and query plans, do not flush pending writes, and preserve
transaction and driver error types unchanged. Custom domain repositories may
use this facade internally while continuing to accept the active manager, as
in the service pattern above.

`delete(Entity, id)` uses the entity's exact non-nil lookup ID type. It loads or
reuses the managed entity, schedules `remove`, and returns `false` when no row
exists. The DELETE still occurs at explicit or transaction-completion flush,
so version checks and rollback behavior remain identical to `remove(entity)`.

No query performs an implicit flush. A normal block return flushes, commits,
then closes the manager. An application, flush, or driver exception rolls back
and propagates unchanged.

If rollback occurs after an explicit flush, generated IDs or versions may
already have changed in memory even though the database rolled back. Discard
all entities obtained from that failed manager.
