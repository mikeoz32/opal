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
- connection-scoped read queries without opening a database transaction;
- static typed queries and the explicit `DynamicQuery` fallback;
- bulk update with automatic version increment;
- raw SQL followed by explicit identity-map invalidation with `clear`;
- rollback and listener/statement observability in the example specs.
- an HTTP API using `LF::HTTP::App` and `LF::HTTP::Router`, with project/task
  CRUD backed by transaction-local entity managers.
- an Application + DI + controller-discovery HTTP executable where Data
  autoconfiguration owns the data source and startup migrations.

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
