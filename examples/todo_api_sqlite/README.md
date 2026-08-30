# Todo API + SQLite Example

This standalone application is the end-to-end Opal Data v1 example. It uses:

- `LF::Data::Entity` mapping with a generated ID, converter, and optimistic
  version;
- a forward-only `MigrationSet` applied by Data autoconfiguration;
- stateless Todo and audit repositories that receive one transaction-local
  `EntityManager`;
- an application service that owns transaction boundaries and composes both
  repositories atomically;
- HTTP controller discovery, constructor DI, and Data/HTTP lifecycle ordering.

## Run

From this directory:

```bash
shards install
crystal run src/todo_api_sqlite_example.cr
```

The default configuration starts the server on `http://127.0.0.1:8083` and
uses `sqlite3://./todo.db`. Set `OPAL_CONFIG=/path/to/application.yml` to select
another file.

`TodoApplication` enables both `@[LF::AutoConfig::Data]` and
`@[LF::AutoConfig::HTTP]`. Startup opens one DataSource, applies the migration,
then binds HTTP. Shutdown drains HTTP before closing SQLite.

## Endpoints

- `GET /todos`
- `GET /todos/:id`
- `POST /todos`
- `PUT /todos/:id`
- `DELETE /todos/:id`

Create:

```bash
curl -X POST http://127.0.0.1:8083/todos \
  -H "content-type: application/json" \
  -d '{"title":"write docs"}'
```

Update:

```bash
curl -X PUT http://127.0.0.1:8083/todos/1 \
  -H "content-type: application/json" \
  -d '{"completed":true}'
```

## Verify

```bash
crystal spec --no-color
shards build --release
```

The specs cover repository CRUD, time conversion, optimistic locking,
multi-repository rollback, process-level HTTP behavior, restart persistence,
and migration idempotency.
