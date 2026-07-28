# ADR-0005: Crystal-Native Data Mapper and Explicit Unit of Work

- Status: Accepted
- Date: 2026-07-28
- Deciders: Opal maintainers
- Extends: ADR-0002 and ADR-0003
- Related: `DB::Database`, `DB::Transaction`, `LF::ApplicationExtension`

## Context

Opal needs a database layer that works for a small SQLite application without
closing the path toward PostgreSQL and larger transactional applications.
`crystal-db` already provides drivers, connection pooling, prepared statements,
transactions, result sets, and driver-specific errors. It does not provide
entity persistence, an identity map, typed query composition, schema
migrations, or application bootstrap integration.

The current Todo SQLite example owns `DB::Database` in an application service,
creates its schema in a lifecycle callback, and repeats SQL and result-set
mapping in a repository. This is explicit and understandable, but each
application must rebuild resource ownership, transactions, mapping, generated
IDs, concurrency checks, and migration history.

An Active Record design is rejected. Entity classes must not obtain global
database state or persistence methods such as `save`, `find`, and `delete`.
Runtime discovery, implicit queries, dirty checking, and automatic schema
synchronization would hide behavior and introduce work that Crystal can perform
at compile time.

A direct copy of JPA or SQLAlchemy is also rejected. Their names and concepts
can inform boundaries, but their APIs and runtime behavior reflect Java and
Python constraints. Opal should use Crystal modules, macros, static types,
block-based resource management, and structural converter protocols.

## Decision Drivers

- No global connection, entity, converter, listener, or repository registry.
- No dependency from `LF::DI` to Application or Data.
- No dependency from Data core to Application, DI, HTTP, or a concrete driver.
- SQL execution and transaction boundaries must remain observable.
- Static metadata and CRUD SQL must be generated at compile time.
- Query structure uses compile-time shape types by default; runtime values
  remain bound parameters.
- Arbitrary runtime filter collections remain possible through an explicit
  dynamic-query API.
- A transaction must own exactly one short-lived persistence context.
- The first release must avoid snapshots, proxy objects, lazy loading, and
  automatic dirty checking.
- Simple applications should need little setup, while manual construction must
  remain available for standalone libraries and tests.

## Considered Designs

### Active Record

Entities expose persistence methods and locate a global or class-level
connection. This is concise for small applications but couples the domain model
to infrastructure, hides resource ownership, complicates tests, and creates
global mutable state. Rejected.

### Stateless Data Mapper

Repositories execute every insert, update, and delete immediately. This is
explicit and small, but it cannot guarantee object identity within a
transaction and provides no coherent place for generated IDs, optimistic
locking, operation coalescing, or future batching. Rejected as the primary API;
raw `crystal-db` remains available when this behavior is desired.

### Managed Persistence Context with Dirty Checking

Loaded entities are snapshotted and automatically updated at query or commit
time. This resembles JPA but introduces hidden writes, snapshot memory,
non-obvious flush rules, and mutation tracking overhead. Rejected for v1.

### Explicit Unit of Work

A transaction-local manager provides identity, typed loading, explicit
`persist`/`remove`, and a queued flush. No SQL write occurs because a property
was merely assigned. Accepted.

## Package Boundaries

The dependency direction is:

```text
crystal-db
    ^
    |
LF::Data
    ^
    |
LF::Data::Dialects::SQLite

LF::Application + LF::DI + LF::ConfigService + LF::Data
    ^
    |
LF::Data::AutoConfig
```

`require "opal"` does not load the data layer. Applications opt into the core
with:

```crystal
require "opal/data"
```

Application integration additionally requires:

```crystal
require "opal/autoconfig/data"
```

Manual SQLite use additionally loads the concrete dialect:

```crystal
require "opal/data/dialects/sqlite"
```

The concrete SQLite driver remains an application dependency:

```crystal
require "sqlite3"
```

The root Opal shard depends on `crystal-db` so `opal/data` can compile. It does
not depend on `crystal-sqlite3` at runtime. SQLite is a development dependency
for Opal integration tests and an explicit dependency of the Todo example.

## DataSource

`LF::Data::DataSource` is the long-lived data entry point. It owns or borrows a
`DB::Database`, stores a dialect instance and listener instances, and creates
transaction-local entity managers.

Two construction modes make ownership explicit:

```crystal
source = LF::Data::DataSource.open(
  url,
  dialect: LF::Data::Dialects::SQLite.new
)

source = LF::Data::DataSource.new(
  database,
  dialect: LF::Data::Dialects::SQLite.new,
  owns_database: false
)
```

`open` owns and closes the created database. `new` borrows by default and does
not close the supplied database. `close` is idempotent. Starting a transaction
after close raises `LF::Data::ClosedDataSourceError`.

Transactions use the Crystal block result as their return value:

```crystal
result = source.transaction do |entity_manager|
  # application work
end
```

The datasource delegates connection checkout, begin, commit, rollback, and
prepared-statement caching to `crystal-db`. It does not retry transactions,
change isolation, or introduce fiber-local transaction state in v1.

## Entity Model

A persistent entity is a reference type that explicitly includes the mapping
module:

```crystal
class Todo
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  property title : String
  property completed : Bool

  @[LF::Data::Version]
  getter version : Int64 = 0

  def initialize(@title : String, @completed : Bool = false)
  end
end
```

Persistent structs are rejected at compile time because copying a value would
make identity-map and lifecycle semantics ambiguous. Structs remain valid query
projections outside the entity manager.

The default table name is the unqualified class name converted to exact
`snake_case`: `Admin::AuditEvent` maps to `audit_event`. No pluralization or
inflection is performed. An explicit `@[LF::Data::Table("audit_events")]`
overrides the convention.

All instance variables are persistent unless ignored. Their default column
name is exact `snake_case`. `LF::Data::Column` supports:

- `name`: explicit column name;
- `ignore`: excludes an instance variable from mapping and writes;
- `converter`: a type implementing the load/dump protocol.

Exactly one instance variable must have `LF::Data::Id`. A single-column
application-assigned ID may use any supported mapped scalar type. A generated
ID is nilable before its first successful flush and is written through a
generated framework-internal persistence method. Composite IDs are not
supported in v1.

An optional `LF::Data::Version` field is a non-nil `Int64` getter initialized to
zero for new entities. Application code does not receive a public version
setter. The manager writes it through generated internal code.

Entity hydration does not call the domain constructor. The macro generates a
dedicated result-set constructor that allocates and initializes persistent
state. This follows the separation used by Crystal serialization modules:
domain construction validates new objects, while hydration restores persisted
objects.

## Compile-Time Generation

Including `LF::Data::Entity` generates:

- validated table, ID, version, and column metadata;
- a stable selected-column list;
- direct bind tuples for INSERT, UPDATE, DELETE, and find-by-ID;
- a result-set hydrator;
- internal generated-ID and version writers;
- typed field marker types and descriptors under `Entity::Fields`.

Compilation fails with an actionable entity and field name when:

- a struct includes `Entity`;
- zero or multiple ID fields exist;
- two properties map to the same column;
- a generated ID has an unsupported type or non-nil declaration;
- a version field is missing, nilable, not `Int64`, or publicly writable;
- a direct field type cannot be represented by `DB::Any`;
- a converter does not satisfy its typed load/dump calls.

There is no global entity scan. Generic `EntityManager` methods compile only
for the concrete entity types used by the executable.

## Value Conversion

Portable direct fields use the `DB::Any` types supported by `crystal-db`.
Domain-specific values use a per-field converter:

```crystal
module UUIDAsString
  def self.load(result : DB::ResultSet) : UUID
    UUID.new(result.read(String))
  end

  def self.dump(value : UUID) : DB::Any
    value.to_s
  end
end
```

Converters are stateless types referenced by metadata. There is no runtime
converter registry. Nil handling belongs to generated mapping code; the
converter receives only non-nil values.

## EntityManager and Entity States

`LF::Data::EntityManager` exists only inside one datasource transaction. It is
not thread-safe, injectable as a singleton, or retained after the transaction
block.

The internal states are:

- `New`: first seen through `persist`, not yet inserted;
- `Managed`: loaded or successfully inserted, associated with this manager;
- `Removed`: scheduled for deletion;
- `Detached`: no longer eligible for managed writes;
- terminal manager: flush failed, transaction ended, or manager closed.

The transition rules are:

| Current state | `persist` | `remove` |
| --- | --- | --- |
| Unknown | schedule INSERT as `New` | raise state error |
| New | coalesce, keep latest values | cancel INSERT and detach |
| Managed | schedule/coalesce UPDATE | schedule DELETE |
| Removed | raise state error | no-op |
| Detached | raise detached error | raise detached error |

An unknown object is always treated as new. The manager does not infer
detached state from a non-nil assigned ID. If its ID already exists, the
database uniqueness constraint fails. Updating detached input requires loading
the managed entity first or using typed bulk DML.

The identity map key consists of entity type plus converted primary-key value.
`find` and entity queries return the existing managed instance when that key is
already present. Result-set data does not silently overwrite an already managed
instance.

Operations are coalesced per object identity and retain their first scheduling
position. An UPDATE writes every persistent non-ID, non-version field because
v1 has no dirty snapshots. Generated IDs are applied only after a successful
INSERT statement.

## Flush and Transaction Semantics

`persist` and `remove` do not execute SQL. `flush` executes queued operations.
Entity queries never trigger a flush.

On normal transaction-block return:

1. the datasource calls `EntityManager#flush`;
2. `crystal-db` commits the transaction;
3. the manager becomes closed;
4. the block result is returned.

On block or flush exception:

1. `crystal-db` rolls back;
2. the manager becomes terminal;
3. the original exception propagates;
4. the connection returns to the pool.

The manager cannot restore arbitrary user mutations after rollback. Generated
ID and version changes are therefore applied only after their statement
succeeds, but an application must discard entities from a rolled-back manager.

An explicit `flush` is required when a generated ID or database-visible state
is needed before block completion. Repeated successful flushes are allowed.
After any flush failure, every manager operation raises
`LF::Data::FailedEntityManagerError`.

No nested transaction or savepoint API is provided in v1. Lower-level services
compose transactionally by accepting the same manager argument.

## Optimistic Locking

For a versioned entity, hydration stores the loaded version in manager state.
UPDATE uses:

```sql
UPDATE table
SET columns..., version = version + 1
WHERE id = ? AND version = ?
```

DELETE also constrains ID and version. Exactly one affected row is required.
Zero affected rows raise `LF::Data::OptimisticLockError`, mark the manager
failed, and cause transaction rollback. A successful UPDATE increments both
database and in-memory versions.

## Typed Query Model

Entity macros generate typed field marker types and descriptors:

```crystal
Todo::Fields.completed.eq(false)
Todo::Fields.title.like("%opal%")
Todo::Fields.id.in({1_i64, 2_i64})
```

Supported v1 expressions are `eq`, `ne`, `lt`, `lte`, `gt`, `gte`, `in`,
`is_nil`, `is_not_nil`, and `like`. Boolean expressions compose through
explicit `and`, `or`, and `not` methods. Repeated `where` calls combine with
AND.

```crystal
todos = entity_manager.query(Todo)
  .where(Todo::Fields.completed.eq(false))
  .where(Todo::Fields.title.like("%opal%"))
  .order_by(Todo::Fields.id.desc)
  .limit(20)
  .offset(0)
  .to_a
```

Terminal operations are `to_a`, `first?`, `count`, and `exists?`. Queries load
complete entities using their generated selected-column list. Partial
projection and join mapping are deferred.

Every fluent operation changes the query's static type. For example, the query
above has a shape equivalent to:

```crystal
SelectQuery(
  Todo,
  And(Eq(Todo::Fields::Completed), Like(Todo::Fields::Title)),
  OrderBy(Todo::Fields::Id, Desc),
  WithLimit,
  WithOffset
)
```

The expression structs store only runtime values. The concrete dialect's
generic method specializes for the entity and query-shape types and emits the
final SQL string at compile time. The query generates a direct tuple of bind
values in the same static order:

```sql
SELECT ... WHERE "completed" = ? AND "title" LIKE ?
ORDER BY "id" DESC LIMIT ? OFFSET ?
```

Identifiers, operators, ordering direction, grouping, and placeholder count
never come from runtime values. Limit and offset are values and therefore use
placeholders. Query execution passes the generated SQL and tuple to
`DB::Connection#query` or `#exec`; `crystal-db` owns preparation and
per-connection prepared-statement caching.

A runtime branch may produce a union of query-shape types. Crystal compiles one
SQL specialization for each union member. Code that builds an arbitrary number
of predicates in a loop must opt into `EntityManager#dynamic_query(T)`.
`DynamicQuery` uses the same typed field descriptors and bound values but
renders SQL at runtime. It is never selected implicitly.

Fixed-arity `IN` accepts a Tuple and produces a static placeholder count. An
Array has runtime arity and is accepted only by `DynamicQuery`. An empty static
Tuple emits a false expression instead of invalid SQL. Negative limit or offset
raises `LF::Data::InvalidQueryError`.

User values never enter SQL text in either mode.

Typed bulk writes use:

```crystal
entity_manager.update(Todo)
  .set(Todo::Fields.completed, true)
  .where(Todo::Fields.id.eq(id))
  .execute

entity_manager.delete(Todo)
  .where(Todo::Fields.completed.eq(true))
  .execute
```

Successful bulk UPDATE or DELETE marks all currently managed entities of that
type detached because their in-memory state may be stale. Bulk operations do
not flush queued entity operations first.

The active `DB::Connection` remains available as an advanced raw SQL escape
hatch. Raw writes bypass Unit of Work guarantees. `clear(T)` detaches every
managed entity of one type when that type has no pending entity operations;
otherwise it raises `EntityStateError`. Application code must call `clear(T)`
for affected types or abandon the manager before further managed operations.

## Dialect Architecture

A database driver and a SQL dialect are different dependencies:

- a `crystal-db` driver opens connections, binds values, executes statements,
  reads result sets, and reports driver errors;
- an `LF::Data::Dialect` converts Opal's typed operation model into
  database-specific SQL and describes how statement results are interpreted.

Data core defines only the abstract dialect contract and operation-plan value
types. It does not require a concrete dialect:

```crystal
abstract class LF::Data::Dialect
  abstract def name : String
  abstract def quote_identifier(identifier : String) : String
  abstract def placeholder(position : Int32) : String

  abstract def find_plan(entity : T.class) : SQL::StatementPlan forall T
  abstract def insert_plan(entity : T.class) : SQL::InsertPlan forall T
  abstract def update_plan(entity : T.class) : SQL::StatementPlan forall T
  abstract def delete_plan(entity : T.class) : SQL::StatementPlan forall T
  abstract def select_plan(
    entity : T.class,
    shape : S.class
  ) : SQL::StatementPlan forall T, S

  abstract def supports?(capability : DialectCapability) : Bool
end
```

`StatementPlan` contains only final SQL. `InsertPlan` additionally contains the
generated-key strategy and optional returned column. It does not contain bind
values or a runtime bind-order array.

Entity annotations and instance variables remain the single mapping source of
truth. A concrete dialect implements the generic methods with Crystal macros
that inspect `T` and, for queries, `S`. Each used
`Entity + Dialect + QueryShape` combination therefore produces final
dialect-specific SQL during compilation. Entity- and query-generated methods
produce direct bind tuples; runtime does not scan metadata, dispatch through
`BindSlot`, or build static SQL with `String::Builder`.

The abstract dialect reference stored by `DataSource` remains sufficient:
Crystal specializes and dispatches generic virtual methods to the concrete
dialect. `DataSource` and `EntityManager` do not need a dialect type parameter.

`quote_identifier` and `placeholder` remain in the base contract for schema
rendering and the explicit `DynamicQuery` path. Dynamic SQL is rendered per
execution because its structure is not known to the compiler.

An `InsertPlan` explicitly describes how a generated key is obtained:

- no generated key: execute and ignore generated-key data;
- `LastInsertId`: execute and convert `DB::ExecResult#last_insert_id`;
- `ReturningRow`: execute as a query and read the declared returned column.

This prevents the base contract from assuming SQLite's last-insert-ID behavior
and permits a future PostgreSQL dialect to use `RETURNING` without changing
EntityManager's public API.

The v1 concrete implementation is:

```crystal
LF::Data::Dialects::SQLite < LF::Data::Dialect
```

It lives under the optional `opal/data/dialects/sqlite` entrypoint. It uses
double-quoted identifiers, `?` placeholders, SQLite pagination,
`LastInsertId`, and SQLite schema rendering. It does not require or register
the `sqlite3` driver; the application must require that shard itself.

Schema behavior is separated from DML rendering. The base package defines
typed schema operations and an abstract `SchemaRenderer`. SQLite supplies
`LF::Data::Dialects::SQLite::SchemaRenderer`. `MigrationRunner` asks its
DataSource dialect for a schema renderer and raises
`UnsupportedSchemaOperationError` when a capability is absent.

`DialectCapability` is a closed framework enum for behavior that changes
execution, initially generated keys, transactional DDL, add column, rename
column, and foreign-key DDL. It is not a registry of arbitrary vendor features.

The dialect contract does not normalize arbitrary SQL, isolation levels,
native types, JSON operators, upsert syntax, locking clauses, or driver value
conversion. PostgreSQL and MySQL dialects are deferred and will receive
separate execution plans and integration suites.

## Migrations

Migrations are explicit compiled Crystal classes:

```crystal
class CreateTodos < LF::Data::Migration
  def version : Int64
    2026072801_i64
  end

  def name : String
    "create_todos"
  end

  def up(schema : LF::Data::SchemaEditor) : Nil
    schema.create_table("todo") do |table|
      table.generated_id("id")
      table.string("title", null: false)
      table.bool("completed", null: false, default: false)
      table.int64("version", null: false, default: 0_i64)
    end
  end
end
```

An application explicitly creates `MigrationSet.new(CreateTodos.new, ...)`.
The runner validates unique, strictly ascending positive versions before
executing SQL. It stores version, name, and application timestamp in
`_lf_migrations`.

Each pending migration and its history insert run in one transaction when the
dialect supports transactional DDL. Failed migrations are not recorded.
Already applied versions are skipped. An applied version with a different name
is an error.

The portable schema DSL covers create/drop table, scalar columns, generated
primary keys, foreign keys, unique constraints, indexes, add column, and rename
column. Unsupported SQLite alterations raise
`LF::Data::UnsupportedSchemaOperationError`. Raw SQL is an explicit method on
the schema editor.

Migrations are forward-only. `down`, automatic schema generation from entity
metadata, automatic destructive changes, and source checksums are excluded.

## Application Autoconfiguration

Application receives a generic conditional autoconfiguration mechanism rather
than Data-specific code. An application extension descriptor declares:

- the marker annotation that enables it;
- an integer priority;
- a zero-argument extension type.

Application bootstrap installs enabled extensions after application bean
providers are registered and before the runtime is returned. Extension stop
order remains the reverse of installation order. `LF::Application` does not
reference `LF::Data`.

Data opts in with:

```crystal
require "opal/autoconfig/data"
require "sqlite3"

@[LF::Application]
@[LF::AutoConfig::Data]
class TodoApplication
end
```

The Data extension reads:

```yaml
database:
  url: sqlite3://./todo.db
  migrations:
    run_on_startup: false
```

The URL is mandatory when the marker is present. The extension selects the
SQLite dialect from the `sqlite3` URI scheme, opens the datasource, registers
the same instance as a singleton bean, and owns its shutdown. Unsupported
schemes and invalid configuration raise
`LF::Data::AutoConfig::ConfigurationError`.

If startup migrations are enabled, the extension resolves exactly one
application-defined `MigrationSet` bean and runs it before bootstrap returns.
No set is resolved when startup migration is disabled. Enabled migration with
no set is a configuration error.

Data autoconfiguration is installed before the current HTTP extension. Runtime
shutdown therefore stops and drains HTTP first, closes Data second, and
destroys remaining DI beans last.

## Observability

`DataSource` accepts listener instances through its constructor. There is no
global listener registry or built-in SQL logger.

Listeners observe transaction begin/commit/rollback and statement completion
with operation kind, entity type when available, SQL text, elapsed time, rows
affected, and exception. Bind values are excluded from the default event to
avoid accidental credential or personal-data logging.

A listener exception must not replace a database or application exception.
Listener failures are ignored by core v1; production listener implementations
are expected to report internally.

## Error Contract

All framework-owned runtime errors inherit `LF::Data::Error`. Public subclasses
include:

- `ClosedDataSourceError`;
- `ClosedEntityManagerError`;
- `FailedEntityManagerError`;
- `EntityStateError`;
- `DetachedEntityError`;
- `MappingError`;
- `InvalidQueryError`;
- `OptimisticLockError`;
- `MigrationError`;
- `DuplicateMigrationVersionError`;
- `MigrationHistoryMismatchError`;
- `UnsupportedSchemaOperationError`.

Driver, pool, connection, and SQL errors remain their original `DB::Error`
subclasses. Autoconfiguration errors use
`LF::Data::AutoConfig::ConfigurationError`.

## Performance Constraints

- Entity discovery and mapping metadata are compile-time only.
- Static CRUD/find SQL is specialized at compile time for each used
  entity/dialect combination.
- Static query SQL is specialized at compile time for each used
  entity/dialect/query-shape combination.
- There is no per-operation metadata reflection or string-key field lookup.
- Opal has no SQL plan or prepared-statement cache; prepared-statement creation
  and per-connection caching remain delegated to `crystal-db`.
- Static execution passes generated bind tuples directly; it performs no SQL
  rendering, bind-slot traversal, or `Array(DB::Any)` construction.
- Runtime SQL rendering and dynamic bind arrays exist only behind the explicit
  `DynamicQuery` API.
- Identity maps, operation queues, and query value objects are
  transaction-local.
- No entity snapshots are allocated.
- Reading never triggers an implicit write.
- Listener cost is absent when no listeners are configured.
- No separate benchmark suite is required for v1; regression specs verify SQL
  counts and absence of implicit queries.

## Consequences

Applications gain a consistent persistence context, typed mapping, generated
CRUD, typed query composition, optimistic locking, and migrations without
placing infrastructure methods on domain objects.

The explicit model requires application services to pass an entity manager into
repository methods when several repositories participate in one transaction.
Updates require `persist`, and generated IDs needed mid-transaction require
`flush`.

The first release intentionally does not solve every ORM problem. Relations,
lazy loading, cascades, joins, projections, composite IDs, entity inheritance,
savepoints, second-level cache, generated repositories, `attach`, `merge`, and
dirty checking require separate ADRs.
