# Tutorial: a database-backed Todo API

The repository has a complete, executable SQLite application in
[`examples/todo_api_sqlite`](https://github.com/mikeoz32/opal/tree/main/examples/todo_api_sqlite).
This tutorial explains the order in which to read and adapt it.

## 1. Add the Data imports and driver

The application owns its concrete driver. For SQLite, add `sqlite3` to the
application shard and require it next to the selected Opal dialect:

```crystal
--8<-- "examples/documentation/todo_data.cr:imports"
```

For PostgreSQL, use `pg` and `opal/data/dialects/postgresql` instead. The Data
API does not silently choose a database dialect.

## 2. Map an entity

`LF::Data::Entity` is an opt-in mixin. The mapping annotations are validated at
compile time and produce the model needed by queries, inserts, updates, and
schema tools.

```crystal
--8<-- "examples/documentation/todo_data.cr:entity"
```

The entity does not lazy-load anything. Associations and queries are explicit
operations inside a transaction.

## 3. Open a source and apply migrations

`DataSource` owns a connection pool created from a URL. A migration runner
uses a forward-only `MigrationSet` and records history in `_lf_migrations`.

```crystal
--8<-- "examples/documentation/todo_data.cr:migration"
```

The manually opened source is closed in `ensure`. In a server application,
Data autoconfiguration owns the source and closes it during application
shutdown instead.

Production PostgreSQL migrations acquire an advisory lock before planning or
executing history. Read [Migrations and locks](../data/migrations.md) before
enabling startup migrations.

## 4. Keep work inside a transaction

`EntityManager` is transaction-local. A repository receives it as a method
argument or is created inside the block; it is never a singleton service.

```crystal
--8<-- "examples/documentation/todo_data.cr:create"
```

Use a repository when an operation is a reusable domain query:

```crystal
--8<-- "examples/documentation/todo_data.cr:query"
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
crystal run src/todo_api_sqlite_example.cr
```

Continue with the dedicated Data reference for [entities](../data/entities.md),
[queries](../data/queries.md), and [relationships](../data/relationships.md).
