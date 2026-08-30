# ADR-0005: Crystal-Native Data Mapper and Explicit Unit of Work

- Status: Accepted
- Date: 2026-07-28
- Amended: 2026-08-30 (relationships, cascades, and repository conveniences)
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
- The first release must avoid snapshots and automatic dirty checking.
- Proxy objects, lazy loading, and implicit relationship queries are permanent
  non-goals; all database access remains explicit.
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

That adapter belongs to the separate application-bootstrap layer and is not
part of the standalone Data core package described by this ADR.

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

The implementation holds an explicit `DB::Database#using_connection` scope and
runs `DB::Connection#transaction` inside it. This lets `crystal-db` complete
commit or rollback first, then closes the transaction-local `EntityManager`,
and only then returns the connection to the pool. The transaction block is
typed as `EntityManager` from the start; there is no intermediate public
`TransactionManager` protocol that Plan 05 would need to replace.

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

The application-facing non-nil ID type is generated as entity metadata and is
the exact type accepted by lookup and delete-by-ID operations. Generated
`Int32?` and `Int64?` properties expose non-nil `Int32` and `Int64` lookup
types; lifecycle nilability never permits a nil lookup. Converters validate the
application-facing ID before producing the database identity-map value.

An optional `LF::Data::Version` field is a non-nil `Int64` getter initialized to
zero for new entities. It cannot also be the ID, be ignored, or define a
converter. Application code does not receive a public version setter. The
manager writes it through generated internal code.

Entity hydration does not call the domain constructor. The macro generates a
dedicated result-set constructor that allocates and initializes persistent
state. This follows the separation used by Crystal serialization modules:
domain construction validates new objects, while hydration restores persisted
objects.

Ignored fields must be nilable or declare an ivar default. Constructor-free
hydration initializes them to nil or that default, preventing partially
initialized entity instances.

## Compile-Time Generation

Including `LF::Data::Entity` generates:

- validated table, ID, version, and column metadata;
- a stable selected-column list;
- direct bind tuples for INSERT, UPDATE, DELETE, and find-by-ID;
- a result-set hydrator;
- internal generated-ID and version writers;
- an exact, non-nil lookup ID descriptor;
- typed field descriptors exposed through `Entity::Fields`.

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
converter registry. Generated dump code bypasses converters for nil property
values. Because `DB::ResultSet` is forward-only, load converters consume their
column directly and own nullable stored-value handling.

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

`delete(T, id)` accepts the same exact lookup ID type as `find(T, id)`, loads or
reuses the managed entity, and schedules its normal `remove` transition. It
returns false when no row exists and does not bypass optimistic locking or
flush ownership.

Operations are coalesced per object identity and retain their first scheduling
position. An UPDATE writes every persistent non-ID, non-version field because
v1 has no dirty snapshots. Generated IDs are applied only after a successful
INSERT statement.

The manager implements heterogeneous scheduling with internal
`TypedTrackedEntity(T)` wrappers. A wrapper stores the entity reference and
lifecycle bookkeeping but no field snapshot or bind collection; concrete
generated tuples are read only when that wrapper executes. Object state and
database identity use separate manager-local hashes.

The operation queue uses append-only nullable slots and a head cursor.
Successful bulk flush is O(n) overall rather than repeatedly shifting an
array. Cancelling a New entity may scan pending slots, which keeps the common
flush path allocation-free and constant-time per completed operation.

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
succeeds. A later transaction rollback can still occur after a successful
explicit flush has advanced the in-memory version, so an application must
discard every entity from a rolled-back manager. Such entities are invalid for
reuse even when their in-memory values look usable; the manager is terminal
after the failed transaction.

An explicit `flush` is required when a generated ID or database-visible state
is needed before block completion. Repeated successful flushes are allowed.
After any flush failure, every manager operation raises
`LF::Data::FailedEntityManagerError`.

INSERT execution branches only on the dialect plan's `GeneratedKeySource`.
`LastInsertId` consumes `DB::ExecResult#last_insert_id`; `ReturningRow` reads
exactly one returned integer row. Assigned IDs use `None`. The generated ID is
written and registered in the identity map only after successful statement
execution.

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

SQLite may reject an overlapping stale read transaction when it attempts to
upgrade to a writer after another connection commits. That native
`database is locked` failure happens before compare-and-set row counts are
available and remains a driver error; Opal does not relabel it as an optimistic
conflict.

## Relationships And Cascades

Entity navigation properties may declare compile-time `BelongsTo`, `HasMany`,
or `HasOne` metadata. Every declaration explicitly names a scalar foreign-key
property. Navigation properties are excluded from stored columns, hydration,
CRUD SQL, and query field descriptors; the scalar key remains the persistence
and query contract.

Hydration assigns nil to `belongs_to`/`has_one` navigation properties and an
empty array to `has_many`. Opal never loads a relation implicitly. Repositories
query related entities explicitly and attach them to the in-memory graph when
that graph is needed.

`cascade_persist` enrolls new in-memory targets in the same manager. Managed
targets are not implicitly scheduled for update. `cascade_remove` is supported
only from `has_many` and `has_one` owners to targets that were explicitly loaded
and are already managed by the same transaction. `belongs_to` remove cascade
and orphan removal are rejected at compile time. Removing an object from a
collection has no persistence effect.

At flush, the manager derives a dependency graph from queued objects and their
in-memory relationship references. Parent inserts precede dependent inserts;
dependent deletes precede parent deletes. Independent operations preserve
their first scheduling order. Cycles fail before queued SQL executes.

Foreign-key DDL remains separate from EntityManager behavior. A typed
`Relations` descriptor may be applied explicitly to a `Schema::TableBuilder`;
it adds a normal foreign key, and `has_one` also adds uniqueness. It does not
infer tables or columns, register entities globally, or generate database-level
delete cascades.

## Typed Query Model

Entity macros generate typed field descriptors:

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
  And(Eq(typeof(Todo::Fields.completed)), Like(typeof(Todo::Fields.title))),
  OrderBy(typeof(Todo::Fields.id), Desc),
  WithLimit,
  WithOffset
)
```

Each descriptor type is
`Field(EntityType, PropertyType, declaration_index)`. The numeric generic
argument distinguishes fields at compile time and resolves the original ivar
annotation without a runtime field-name or metadata registry.

The expression structs store only runtime values. Data core's shared static
plan compiler is installed into each concrete dialect and specializes for the
entity and query-shape types. It applies that dialect's static policy and emits
the final SQL string at compile time. The query generates a direct tuple of
bind values in the same static order:

```sql
SELECT ... WHERE "completed" = ? AND "title" LIKE ?
ORDER BY "id" DESC LIMIT ? OFFSET ?
```

Identifiers, operators, ordering direction, grouping, and placeholder count
never come from runtime values. Limit and offset are values and therefore use
placeholders. Query execution passes the generated SQL and tuple to
`DB::Connection#query` or `#exec`; `crystal-db` owns preparation and
per-connection prepared-statement caching.

Expression and ordering shapes expose class-level typed tuples of empty SQL
token structs. `typeof` supplies the flattened token types to the static
compiler; no expression instance or query value is passed to SQL generation.
This avoids recursive runtime rendering while preserving explicit grouping and
stable depth-first bind order. Dialect subclasses inherit the nearest static
SQL policy and may override it with their own nested policy constant.

A runtime branch may produce a union of query-shape types. Crystal compiles one
SQL specialization for each union member. Code that builds an arbitrary number
of predicates in a loop must opt into `EntityManager#dynamic_query(T)`.
`DynamicQuery` uses the same typed field descriptors and bound values but
renders SQL at runtime. It is never selected implicitly.

`DynamicQuery` is mutable so loop-based filters can append to one runtime
shape. It boxes concrete typed expressions behind entity-specific predicate
nodes; field identity and the closed operator set remain compile-time checked.
`DynamicRenderer` reads generated table/column literals, delegates runtime
quoting, placeholders, and offset-only syntax to the concrete dialect, and
returns `RenderedQuery(String, Array(DB::Any))`. The array is passed through
crystal-db's `args:` API without becoming a static bind representation.

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
not flush queued entity operations first. Execution is rejected when that
entity type has pending per-entity operations. UPDATE binds SET values before
WHERE values; repeated SET for one field uses the last value while retaining
the field's first SQL position. Whole-table UPDATE and DELETE are allowed only
through an explicit bulk builder execution.

The active `DB::Connection` remains available as an advanced raw SQL escape
hatch through the read-only `EntityManager#connection` getter. It is the
connection owned by the current datasource transaction and is unavailable after
the manager closes or enters its failed state. Driver errors keep their original
type. Raw writes bypass Unit of Work guarantees and do not invalidate the
identity map automatically. `clear(T)` detaches every managed entity of one type
when that type has no pending entity operations; otherwise it raises
`EntityStateError`. Application code must call `clear(T)` for affected types or
abandon the manager before further managed operations.

## Repository Convenience API

`EntityManager#repository(Entity)` returns an optional manager-bound
`Repository(Entity, ID)`. The entity macro supplies the exact application-side
lookup ID type, including removal of `Nil` from generated `Int32?` and `Int64?`
IDs. The repository provides `find`, `find_by`, `count`, `exists?`, and access
to the existing static and dynamic query builders. Entity-typed `persist`,
`remove`, and delete-by-ID delegate queued writes; `update` and `delete_all`
expose the existing typed bulk builders. `flush` remains a manager operation
because it coordinates the complete transaction-local Unit of Work. The
facade generates no new SQL plans and introduces no registry or persistence
methods on entities.

A repository is constructed only from an active transaction-local manager. It
does not accept or own a `DataSource`, open a transaction, flush before reads,
or remain usable after its manager closes. This keeps transaction ownership in
the application service while allowing custom stateless repositories to use a
small typed facade internally.

Pagination is one-based and requires a positive page number, positive page
size, and explicit typed ordering. It may accept an unpaginated composed static
query, preserving repeated predicates and multi-column ordering. It executes
one existing count terminal and one ordered SELECT with limit and offset. An
out-of-range page has no items but retains the matching total; an empty result
has zero total pages. Page navigation predicates are computed from its metadata
without SQL. A query created by another manager fails with
`RepositoryQueryOwnershipError` before SQL execution. Transaction failures and
driver failures propagate with their existing types.

## Dialect Architecture

A database driver and a SQL dialect are different dependencies:

- a `crystal-db` driver opens connections, binds values, executes statements,
  reads result sets, and reports driver errors;
- an `LF::Data::Dialect` converts Opal's typed operation model into
  database-specific SQL and describes how statement results are interpreted.

Data core defines the abstract dialect contract, operation-plan value types,
and the optional shared static plan compiler. It does not require a concrete
dialect:

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
  abstract def update_query_plan(
    entity : T.class,
    shape : S.class
  ) : SQL::StatementPlan forall T, S
  abstract def delete_query_plan(
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
truth. Data core provides `LF::Data::SQL::StaticPlanCompiler`, a compile-time
mixin that installs generic CRUD plan methods into a concrete dialect through
`macro included` and `verbatim`. Installing the methods into the concrete class
is required because an external macro call cannot retain a generic method's
specialized `T` reliably.

The compiler inspects `T` and, for queries, `S`. It owns common SQL structure:
mapping declarations, deterministic column order, standard SELECT/INSERT/
UPDATE/DELETE clauses, and placeholder order. It does not create a runtime
entity descriptor, metadata registry, query-plan cache, or second mapping
source.

Each concrete dialect supplies a small compile-time policy describing only SQL
variation:

- identifier delimiters and escaping;
- positional placeholder form;
- empty-INSERT syntax;
- generated-key result strategy and optional returned-column clause;
- later pagination syntax required by static query shapes.

Runtime `quote_identifier` and `placeholder` behavior must derive from the same
policy or be covered by parity specs so static and dynamic SQL cannot drift. A
dialect may override an installed generic plan method when its SQL cannot be
represented by the common policy.

Each used `Entity + ConcreteDialect + QueryShape` combination therefore
produces final dialect-specific SQL during compilation. `DialectPolicy` is not
a runtime object or an additional generic parameter; it is compile-time input
owned by the concrete dialect. Entity- and query-generated methods produce
direct bind tuples; runtime does not scan metadata, dispatch through `BindSlot`,
or build static SQL with `String::Builder`.

This compiler is not a `BaseDialect` subclass. `LF::Data::Dialect` remains the
runtime polymorphic contract, while static SQL generation is a separate
compile-time collaborator. This avoids pretending that Crystal macros use
runtime virtual dispatch.

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

The concrete implementations are:

```crystal
LF::Data::Dialects::SQLite < LF::Data::Dialect
LF::Data::Dialects::PostgreSQL < LF::Data::Dialect
```

SQLite lives under the optional `opal/data/dialects/sqlite` entrypoint. It uses
double-quoted identifiers, `?` placeholders, SQLite pagination,
`LastInsertId`, and SQLite schema rendering. It does not require or register
the `sqlite3` driver; the application must require that shard itself.

PostgreSQL lives under the optional `opal/data/dialects/postgresql` entrypoint.
It uses double-quoted identifiers, numbered `$1` placeholders, standard offset
pagination, `ReturningRow`, and PostgreSQL schema rendering. It does not require
or register the `pg` driver; the application must require that shard itself.

Schema behavior is separated from DML rendering. The base package defines
typed schema operations and an abstract `SchemaRenderer`. SQLite supplies
`LF::Data::Dialects::SQLite::SchemaRenderer`. `MigrationRunner` asks its
DataSource dialect for a schema renderer and raises
`UnsupportedSchemaOperationError` when a capability is absent.

`DialectCapability` is a closed framework enum for behavior that changes
execution: generated keys, transactional DDL, safe migration locking, schema
inspection, add column, rename column, and foreign-key DDL. It is not a
registry of arbitrary vendor features.

The dialect contract does not normalize arbitrary SQL, isolation levels,
vendor-only types, JSON operators, upsert syntax, row-locking clauses, or
driver value conversion. MySQL and further dialects require separate execution
plans and integration suites.

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

`MigrationSet` preserves declared instance order and exposes no mutable global
registry. Validation runs again at the start of `MigrationRunner#run`, before
the runner opens a datasource transaction. This protects the execution boundary
even when a migration instance exposes mutable version or name state. Pending
work is represented by immutable `PlannedMigration` descriptors containing the
validated version and name; history records that snapshot rather than rereading
the mutable migration object after `up`.

`SchemaEditor` produces typed schema-operation values and delegates them to the
`SchemaRenderer` supplied by the active dialect. Data core contains no concrete
dialect branches. `create_table(..., if_not_exists: true)` is available for
infrastructure bootstrap; a concrete renderer must apply that mode to both the
table and any indexes emitted by the same operation. The migration history uses
this mode to create `_lf_migrations` idempotently.

Each pending migration and its history insert run in one transaction when the
dialect supports transactional DDL. Failed migrations are not recorded.
Already applied versions are skipped. An applied version with a different name
is an error. An applied version absent from the current migration set is also
an error: the executable refuses to run against a schema newer than the set it
knows how to describe. The history remains forward-only and no rollback is
attempted.

The runner pins one checked-out datasource connection for the migration session
and obtains the dialect migration-lock strategy before planning. It opens one
transaction to ensure and read history, then one independent transaction per
pending migration on that same connection. The migration `up` method and its
history insert share a transaction; a failure in either rolls back that
migration and stops later versions, while previously committed versions remain
applied. Driver and SQL exceptions keep their original types.

Concurrent PostgreSQL runners use a session advisory lock acquired before
history planning. Its two-key identifier hashes the current database and an
application namespace, and acquisition has a bounded timeout. SQLite has no
advisory lock: it explicitly retains transactional DDL plus the
`_lf_migrations.version` primary-key reconciliation strategy. Two SQLite
runners may observe a version as pending, but at most one can commit its effects
and history row; the loser rereads exact version/name history. There is no
process-global lock. Arbitrary external side effects remain outside the
transaction guarantee. A dialect missing either `TransactionalDDL` or
`MigrationLock` capability is rejected before history SQL. Lock release is
idempotent, stays on the pinned connection, and cleanup failure is aggregated
with any primary migration failure.

The portable schema DSL covers create/drop/rename table, scalar columns,
generated primary keys, foreign keys, unique constraints, indexes, add column,
and rename column. Unsupported SQLite alterations raise
`LF::Data::UnsupportedSchemaOperationError`. Raw SQL is an explicit method on
the schema editor.

SQLite and PostgreSQL provide dialect-owned schema introspection. An application
may explicitly declare a `Schema::Model`, compare it with an inspected snapshot,
review a deterministic typed diff, and generate a normal Crystal migration
class. Inspection and generation never execute schema changes. Rename hints are
explicit; destructive table/index operations require a generation opt-in;
unresolved column or constraint changes refuse source generation. The migration
history table is unmanaged by default, and application tables may be explicitly
excluded before dialect metadata inspection.

Migrations remain forward-only. `down`, automatic schema generation from entity
metadata, startup schema synchronization, automatic destructive changes, and
source checksums are excluded.

Schema, history select, and history insert statements participate in the same
datasource listener stream as entity operations. `StatementObserver` belongs to
the Data listener contract; `EntityManager` exposes only an internal callback
bridge and has no dependency on migration or schema types.

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
- `RepositoryQueryOwnershipError`;
- `OptimisticLockError`;
- `RelationshipError`;
- `UnsavedRelationshipError`;
- `UnmanagedRelationshipError`;
- `RelationshipKeyMismatchError`;
- `RelationshipCycleError`;
- `MigrationError`;
- `DuplicateMigrationVersionError`;
- `MigrationHistoryMismatchError`;
- `UnsupportedSchemaOperationError`.

Driver, pool, connection, and SQL errors remain their original `DB::Error`
subclasses. Autoconfiguration errors use
`LF::Data::AutoConfig::ConfigurationError`.

## Performance Constraints

- Entity discovery and mapping metadata are compile-time only.
- Relationship descriptors and target validation are compile-time only; no
  runtime relationship registry exists.
- Static CRUD/find SQL is specialized at compile time for each used
  entity/concrete-dialect combination, using the dialect's static policy.
- Static query SQL is specialized at compile time for each used
  entity/concrete-dialect/query-shape combination, using the dialect's static
  policy.
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

The first release intentionally does not solve every ORM problem. Joins,
projections, composite IDs, entity inheritance, savepoints, second-level cache,
generated repositories, `attach`, `merge`, and dirty checking require separate
ADRs. Lazy loading, proxy objects, and implicit relationship queries remain
rejected rather than deferred.
