# Data 11: Todo Example And Public Documentation

> **For Codex:** REQUIRED SKILLS: `executing-plans`,
> `test-driven-development`, `systematic-debugging`, and
> `verification-before-completion`.

**Goal:** Prove the complete Data API in a real HTTP application and publish
documentation that makes SQL, transaction, ownership, and non-goals explicit.

**Architecture:** The Todo application uses Data autoconfiguration and a
versioned migration. Repositories remain stateless application services.
Application services own transaction boundaries and pass one EntityManager to
all participating repositories.

**Prerequisite:** Plans 04 through 10 are merged.

---

## Task 1: Add Todo Entity Mapping

**Files**

- Modify: `examples/todo_api_sqlite/src/todo_api_sqlite_example.cr`

Change `Todo` to:

```crystal
class Todo
  include JSON::Serializable
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  property title : String
  property completed : Bool

  @[LF::Data::Column(converter: TimeAsString)]
  getter created_at : Time

  @[LF::Data::Version]
  getter version : Int64 = 0
end
```

Use a dedicated JSON response shape if making persistence ID nilable would
weaken the external API contract. Persistence annotations must not determine
HTTP serialization behavior.

## Task 2: Replace Schema Callback With Migration

**Files**

- Create: `examples/todo_api_sqlite/src/migrations/create_todos.cr`
- Create: `examples/todo_api_sqlite/src/migrations.cr`
- Modify: `examples/todo_api_sqlite/config/application.yml`

Move all `CREATE TABLE` logic out of `TodoDatabase`. Define an explicit
`MigrationSet` bean in an `@[LF::ApplicationConfiguration]` class. Enable:

```yaml
database:
  url: sqlite3://./todo.db
  migrations:
    run_on_startup: true
```

Delete `TodoDatabase` after tests prove the new migration creates the same
schema.

## Task 3: Refactor Repository Boundaries

`TodoRepository` remains `@[LF::DI::Service]` and injects `DataSource`, not
`DB::Database` or a long-lived EntityManager.

Organize methods as:

```crystal
def find(em : LF::Data::EntityManager, id : Int64) : Todo?
def all(em : LF::Data::EntityManager) : Array(Todo)
def create(em : LF::Data::EntityManager, title : String) : Todo
def update(em : LF::Data::EntityManager, ...) : Todo?
def delete(em : LF::Data::EntityManager, id : Int64) : Bool
```

An application service opens the transaction and delegates to repository
methods. A controller injects that service. This permits one transaction to
compose multiple repositories without fiber-local state.

Add a second lightweight audit repository/use case demonstrating two
repositories sharing one manager and rolling back atomically on failure.

## Task 4: Add Example-Level Tests Before Refactoring

**Files**

- Create: `examples/todo_api_sqlite/spec/spec_helper.cr`
- Create: `examples/todo_api_sqlite/spec/todo_repository_spec.cr`
- Create: `examples/todo_api_sqlite/spec/todo_service_spec.cr`

Capture current behavior before replacing implementation:

- empty list;
- create returns generated ID;
- find existing/missing;
- update title only;
- update completed only;
- delete existing/missing;
- created timestamp survives mapping;
- multi-repository failure rolls back all writes;
- optimistic stale update is reported.

Run these tests red against each incremental replacement before deleting old
code.

## Task 5: Add Process-Level HTTP Verification

**Files**

- Create: `spec/todo_api_process_spec.cr` or keep the process spec inside the
  example if root dependency isolation requires it.

Build the executable under `/tmp`. Start it with:

- temporary config file;
- temporary SQLite path;
- loopback host;
- selected unused port;
- captured stdout/stderr.

Verify through HTTP:

1. `GET /todos` returns empty JSON;
2. `POST /todos` returns generated ID and version;
3. `GET /todos/:id` returns persisted entity;
4. `PUT` updates title/completed and version;
5. list contains the updated row;
6. delete succeeds;
7. missing show/update/delete return 404;
8. restart preserves data;
9. applied migration is not rerun;
10. termination drains HTTP then closes SQLite.

Every process is terminated in `ensure`. Remove executable, config, database,
WAL, and SHM files.

## Task 6: Publish Data Documentation

**Files**

- Modify: `README.md`
- Modify: `examples/todo_api_sqlite/README.md`
- Create: `docs/data/getting-started.md`
- Create: `docs/data/dialects.md`
- Create: `docs/data/entities.md`
- Create: `docs/data/transactions-and-repositories.md`
- Create: `docs/data/queries.md`
- Create: `docs/data/migrations.md`
- Create: `docs/data/autoconfiguration.md`
- Create: `docs/data/raw-sql-and-converters.md`

Required documentation topics:

- required shard dependencies and opt-in requires;
- owned versus borrowed DataSource;
- why EntityManager is transaction-local;
- exact entity state and flush semantics;
- generated versus runtime work;
- repository composition with explicit manager parameter;
- converters and DB-compatible value types;
- optimistic locking and rollback caveat;
- migration deployment/startup choices;
- raw SQL identity-map invalidation;
- all v1 deferred features.

Do not advertise relation mapping, repository generation, automatic timestamps,
schema sync, or transparent retry.

## Task 7: Final Architecture And Performance Audit

Check:

```bash
rg -n "DB\\.open|@@|class_getter|class_property" src/opal/data src/opal/autoconfig/data
rg -n "LF::Application|LF::DI|LF::HTTP|YAML" src/opal/data
rg -n "LF::Data" src/opal/di.cr
```

Review query-count specs for:

- repeated find uses no second SELECT;
- SELECT never auto-flushes;
- one entity operation emits one write;
- static CRUD operation templates are generated once and dialect statement
  plans are not rebuilt per execution;
- no listener path executes when none are configured.

No separate benchmark suite is required for v1.

## Final Verification

```bash
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec --no-color
shards build
git diff --check
git status --short --branch
```

Build and curl the Todo API once more after the full suite. Confirm no process
or generated artifact remains.

Commit as:

```text
refactor(examples): migrate todo API to Opal Data
docs(data): add persistence guides
```

Then use `finishing-a-development-branch` for final review and integration.
