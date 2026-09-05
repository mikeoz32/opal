# Tutorial: a database-backed Todo API

The repository has a complete, executable SQLite application in
[`examples/todo_api_sqlite`](https://github.com/mikeoz32/opal/tree/main/examples/todo_api_sqlite).
This tutorial explains the order in which to read and adapt it.

## 1. Add the Data imports and driver

The application owns its concrete driver. For SQLite, add `sqlite3` to the
application shard and require it next to the selected Opal dialect:

```crystal
require "opal"
require "opal/data"
require "opal/data/dialects/sqlite"
require "sqlite3"
```

For PostgreSQL, use `pg` and `opal/data/dialects/postgresql` instead. The Data
API does not silently choose a database dialect.

## 2. Map an entity

`LF::Data::Entity` is an opt-in mixin. The mapping annotations are validated at
compile time and produce the model needed by queries, inserts, updates, and
schema tools.

```crystal
@[LF::Data::Table("todos")]
class Todo
  include LF::Data::Entity

  @[LF::Data::Id]
  @[LF::Data::GeneratedValue]
  property id : Int64?

  @[LF::Data::Column]
  property title : String

  @[LF::Data::Version]
  property version : Int64?

  def initialize(@title : String, @id : Int64? = nil, @version : Int64? = nil)
  end
end
```

The entity does not lazy-load anything. Associations and queries are explicit
operations inside a transaction.

## 3. Open a source and apply migrations

`DataSource` owns a connection pool created from a URL. A migration runner
uses a forward-only `MigrationSet` and records history in `_lf_migrations`.

```crystal
source = LF::Data::DataSource.open(
  "sqlite3://./todos.db",
  dialect: LF::Data::Dialects::SQLite.new,
)

migrations = LF::Data::MigrationSet.new(CreateTodos.new)
LF::Data::MigrationRunner.new(source).run(migrations)
```

Production PostgreSQL migrations acquire an advisory lock before planning or
executing history. Read [Migrations and locks](../data/migrations.md) before
enabling startup migrations.

## 4. Keep work inside a transaction

`EntityManager` is transaction-local. A repository receives it as a method
argument or is created inside the block; it is never a singleton service.

```crystal
def create(source : LF::Data::DataSource, title : String) : Todo
  source.transaction do |manager|
    todo = Todo.new(title)
    manager.persist(todo)
    manager.flush
    todo
  end
end
```

Use a repository when an operation is a reusable domain query:

```crystal
source.transaction do |manager|
  todos = LF::Data::Repository(Todo).new(manager)
  todos.where { |todo| todo.title.like("%release%") }.to_a
end
```

The [transactions and repositories guide](../data/transactions-and-repositories.md)
defines which query methods are available and their lifecycle constraints.

## 5. Put the transaction behind an HTTP service

An HTTP controller should inject an application-owned `DataSource` or a service
that owns one, then open the transaction around each use case. Do not store the
manager in the controller or a DI singleton.

For a complete server, routes, DTOs, and tests, run the example:

```bash
cd examples/todo_api_sqlite
shards install
crystal run src/todo_api_sqlite.cr
```

Continue with the dedicated Data reference for [entities](../data/entities.md),
[queries](../data/queries.md), and [relationships](../data/relationships.md).
