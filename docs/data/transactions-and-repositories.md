# Transactions And Repositories

Application services own transaction boundaries. Repositories are stateless
and accept the active manager explicitly:

```crystal
class TodoRepository
  def find(manager : LF::Data::EntityManager, id : Int64) : Todo?
    manager.find(Todo, id)
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

No query performs an implicit flush. A normal block return flushes, commits,
then closes the manager. An application, flush, or driver exception rolls back
and propagates unchanged.

If rollback occurs after an explicit flush, generated IDs or versions may
already have changed in memory even though the database rolled back. Discard
all entities obtained from that failed manager.
