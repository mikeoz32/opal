# Data Relationships And Cascades

Opal supports compile-time `belongs_to`, `has_many`, and `has_one` metadata.
Relationships describe an object graph and its foreign-key dependency; they do
not load data, execute joins, or infer a schema.

```crystal
@[LF::Data::Table("projects")]
class Project
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  getter name : String

  @[LF::Data::HasMany(
    foreign_key: "project_id",
    cascade_persist: true,
    cascade_remove: true,
  )]
  getter tasks : Array(Task) = [] of Task

  @[LF::Data::HasOne(
    foreign_key: "project_id",
    cascade_persist: true,
    cascade_remove: true,
  )]
  property profile : ProjectProfile?

  def initialize(@name : String)
    @id = nil
    @profile = nil
  end
end

@[LF::Data::Table("tasks")]
class Task
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  getter project_id : Int64?
  getter title : String

  @[LF::Data::BelongsTo(
    foreign_key: "project_id",
    cascade_persist: true,
  )]
  property project : Project?

  def initialize(@title : String, @project : Project? = nil)
    @id = nil
    @project_id = nil
  end
end

@[LF::Data::Table("project_profiles")]
class ProjectProfile
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  getter project_id : Int64?

  @[LF::Data::BelongsTo(foreign_key: "project_id")]
  property project : Project?

  def initialize(@project : Project? = nil)
    @id = nil
    @project_id = nil
  end
end
```

`belongs_to` and `has_one` properties must be nilable. A `has_many` property
must be an `Array(Target)`. The named scalar foreign-key property remains the
stored/queryable field; the navigation property is excluded from hydration,
CRUD SQL, and `Fields`.

Owner-side `has_many` and `has_one` declarations require a matching
`belongs_to` on the target using the same scalar foreign key. The compiler also
validates target entity types, ID/FK types and converters, annotation flags,
and unsupported combinations.

## Loading Is Always Explicit

Hydration initializes `belongs_to` and `has_one` properties to nil and
`has_many` properties to an empty array. Reading a navigation property never
executes SQL. Load and attach the objects explicitly in a repository or
application service:

```crystal
source.transaction do |manager|
  project = manager.find(Project, project_id).not_nil!
  tasks = manager.query(Task)
    .where(Task::Fields.project_id.eq(project_id))
    .to_a

  project.tasks.concat(tasks)
  project
end
```

Opal has no lazy loading, proxy objects, implicit relationship queries, or
join-based relationship hydration.

## Cascade Ownership

| Action | Owner |
| --- | --- |
| Foreign-key integrity | An explicit database constraint in `Schema::Model` or a migration |
| Insert/delete dependency order | The transaction-local `EntityManager` |
| `cascade_persist` | The `EntityManager`, for new targets reachable in memory |
| `cascade_remove` | The `EntityManager`, for explicitly loaded and tracked `has_many`/`has_one` targets |
| `belongs_to` remove cascade | Rejected at compile time |
| Orphan removal | Unsupported and rejected at compile time |
| Database `ON DELETE` cascade | Outside the relationship contract; never inferred or generated |

`cascade_persist` enrolls new reachable targets. It does not schedule an update
for an already managed target; call `persist` on that target explicitly because
Opal has no dirty checking. Before a dependent INSERT or UPDATE, the manager
copies a non-nil related ID into its scalar foreign-key property. A generated
parent ID therefore becomes available to its children after the parent INSERT.

An unsaved generated-ID target without `cascade_persist` raises
`UnsavedRelationshipError` before the dependent statement executes. A relation
object whose ID disagrees with a non-nil scalar key raises
`RelationshipKeyMismatchError`.

`cascade_remove` never searches the database for children. Every target in the
loaded owner collection/property must already be managed by the same
transaction; otherwise removal raises `UnmanagedRelationshipError`. Unloaded
rows remain untouched and may cause the database foreign-key constraint to
reject the parent delete.

Removing an object from a collection only changes memory. It does not schedule
DELETE or UPDATE. Remove that entity explicitly when the application owns that
operation.

## Flush Ordering And Cycles

Flush builds a transaction-local dependency graph from the objects currently
queued and related in memory. Parents insert before dependents; dependents
delete before parents. Independent operations retain their original scheduling
order.

A dependency cycle raises `RelationshipCycleError` before any queued SQL is
executed. Statement failures, including optimistic-lock conflicts during a
cascade, fail the manager and roll back the whole datasource transaction.

## Schema Metadata

Relationship descriptors are typed and application-local:

```crystal
Task::Relations.project.kind.belongs_to?
Task::Relations.project.target_type
Task::Relations.project.foreign_key_property
```

Apply a descriptor explicitly while building the schema model:

```crystal
schema = LF::Data::Schema::Model.build do |model|
  model.table("projects") do |table|
    table.generated_id("id")
    table.string("name", null: false)
  end

  model.table("tasks") do |table|
    table.generated_id("id")
    table.int64("project_id", null: false)
    table.string("title", null: false)
    table.foreign_key(Task::Relations.project)
  end

  model.table("project_profiles") do |table|
    table.generated_id("id")
    table.int64("project_id", null: false)
    table.foreign_key(Project::Relations.profile)
  end
end
```

The descriptor verifies which table owns the foreign key. A `has_one`
descriptor also adds a unique constraint. Use either the owner-side or
`belongs_to` descriptor for one foreign key, not both. Tables, columns,
nullability, indexes, and the decision to generate a migration remain explicit
application-owned schema declarations.
