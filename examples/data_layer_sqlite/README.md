# Data Layer + SQLite Example

This standalone Crystal application exercises the data layer with both
explicit ownership and Application autoconfiguration. It includes a CLI
showcase and an HTTP API backed by the same data-layer store, plus an
Application-integrated variant using Data and HTTP autoconfiguration.

It demonstrates:

- compile-time entity mapping with generated IDs, a nullable field, a custom
  converter, an ignored field, and optimistic versioning;
- ordered migrations, indexes, uniqueness, and foreign keys;
- `DataSource` ownership and dialect connection setup;
- transaction-local `EntityManager` unit of work operations;
- compile-time `belongs_to`, `has_many`, and `has_one` metadata;
- graph persistence with generated foreign-key propagation and deterministic
  insert ordering;
- explicit relationship loading and loaded-only owner-side remove cascades;
- relationship-driven foreign-key schema metadata, including `has_one`
  uniqueness;
- static typed queries and the explicit `DynamicQuery` fallback;
- bulk update with automatic version increment;
- raw SQL followed by explicit identity-map invalidation with `clear`;
- rollback and listener/statement observability in the example specs.
- an HTTP API using `LF::HTTP::App` and `LF::HTTP::Router`, with project/task
  CRUD backed by transaction-local entity managers.
- an Application + DI + controller-discovery HTTP executable where Data
  autoconfiguration owns the data source and startup migrations.

## Relationship graph

The showcase domain declares a project with tasks and one profile. Each task
belongs to its project and owns task events. Navigation properties are separate
from the scalar foreign-key fields used by SQL and typed queries:

```crystal
@[LF::Data::HasMany(
  foreign_key: "project_id",
  cascade_persist: true,
  cascade_remove: true,
)]
getter tasks : Array(Task) = [] of Task

@[LF::Data::BelongsTo(
  foreign_key: "project_id",
  cascade_persist: true,
)]
property project : Project?
```

Build the graph in memory and persist it through its owner. One flush inserts
the project before its dependents and propagates each generated ID into the
matching scalar key:

```crystal
project = Project.new("opal")
project.profile = ProjectProfile.new(project, "primary")

task = Task.new(project, "write relationship docs")
task.events << TaskEvent.new(task, "created")
project.tasks << task

store.source.transaction do |manager|
  manager.persist(project)
  manager.flush
end

project.id                 # generated project ID
task.project_id            # the same ID, copied before task INSERT
task.events.first.task_id  # generated task ID
```

Hydration never fills navigation properties or issues hidden queries. Query
related rows and attach them explicitly before using owner-side remove
cascades:

```crystal
store.source.transaction do |manager|
  project = manager.find(Project, project_id).not_nil!

  project.tasks.concat(
    manager.query(Task)
      .where(Task::Fields.project_id.eq(project_id))
      .to_a
  )
  project.profile = manager.query(ProjectProfile)
    .where(ProjectProfile::Fields.project_id.eq(project_id))
    .first?

  project.tasks.each do |task|
    task.events.concat(
      manager.query(TaskEvent)
        .where(TaskEvent::Fields.task_id.eq(task.id.not_nil!))
        .to_a
    )
  end

  manager.remove(project)
end
```

The migration uses typed relationship descriptors instead of repeating table
and column names:

```crystal
table.foreign_key(
  Task::Relations.project,
  name: "fk_showcase_tasks_project"
)

# HasOne also contributes a UNIQUE constraint for project_id.
table.foreign_key(Project::Relations.profile)
```

Removing an item from `project.tasks` only mutates the array. It never deletes
the row; call `manager.remove(task)` explicitly. Lazy loading, proxies, orphan
removal, and implicit relationship queries are intentionally absent.

Run the executable:

```bash
shards install
crystal run src/data_layer_example_cli.cr
```

By default it uses an in-memory SQLite database. Use a file-backed database
when you want to inspect migration history or restart behavior:

```bash
OPAL_DATA_EXAMPLE_URL=sqlite3://./data-example.db \
  crystal run src/data_layer_example_cli.cr
```

Run the HTTP application:

```bash
OPAL_DATA_EXAMPLE_URL=sqlite3://./data-example.db \
  OPAL_DATA_HTTP_PORT=8084 \
  crystal run src/data_layer_example_http_cli.cr
```

The HTTP application exposes `GET /health`, project creation/listing, and
task creation/listing/update/deletion routes. For example:

```bash
curl http://127.0.0.1:8084/health
curl -X POST http://127.0.0.1:8084/projects \
  -H 'Content-Type: application/json' \
  -d '{"name":"demo"}'
```

Run the Application-integrated HTTP application:

```bash
cat > /tmp/opal-data-example.yml <<'YAML'
http:
  host: 127.0.0.1
  port: 8085
database:
  url: sqlite3://./data-example-application.db
  migrations:
    run_on_startup: true
YAML

OPAL_CONFIG=/tmp/opal-data-example.yml \
  crystal run src/data_layer_example_application_cli.cr
```

This target uses `@[LF::Application]`, `@[LF::AutoConfig::Data]`,
`@[LF::AutoConfig::HTTP]`, a `MigrationSet` bean, and
`LF::HTTP::Controller` discovery. Data autoconfiguration opens and registers
one `DataSource`, applies migrations before HTTP binds, and closes the source
after HTTP stops.

Run the example integration specs:

```bash
crystal spec --no-color
```

The standalone CLI and router examples wire `LF::Data::DataSource` and
`LF::Data::MigrationRunner` directly. The Application target demonstrates the
autoconfigured path. These HTTP and Application adapters do not add either
dependency to the data core.
