# Data 10: Data Application Autoconfiguration

> **For Codex:** REQUIRED SKILLS: `executing-plans`,
> `test-driven-development`, `systematic-debugging`, and
> `verification-before-completion`.

**Goal:** Configure, register, migrate, and close a DataSource through
`LF::Application` while keeping Data core independent of Application and DI.

**Architecture:** `opal/autoconfig/data` is an adapter package. It declares a
marker and a conditional Application extension using Plan 09's generic
contract. The extension owns the datasource instance it registers.

**Prerequisite:** Plans 03, 08, and 09 are merged. All standalone Data plans
must be complete before this Application adapter begins.

The adapter requires `opal/data` and the bundled
`opal/data/dialects/sqlite` entrypoint. It does not require `sqlite3`; the
application still chooses and loads its concrete `crystal-db` driver.

---

## User Contract

```crystal
require "opal"
require "opal/autoconfig/data"
require "sqlite3"

@[LF::Application]
@[LF::AutoConfig::Data]
class TodoApplication
end
```

```yaml
database:
  url: sqlite3://./todo.db
  migrations:
    run_on_startup: false
```

## Task 1: Add Marker And Compile-Time Validation

**Files**

- Create: `src/opal/autoconfig/data.cr`
- Create: `spec/data_autoconfig_compile_spec.cr`
- Create: `spec/fixtures/data/autoconfig_application.cr`
- Create: `spec/fixtures/data/autoconfig_without_application.cr`
- Create: `spec/fixtures/data/autoconfig_without_marker.cr`

Required behavior:

- requiring the file alone compiles and installs nothing;
- marker plus Application compiles;
- marker on a non-Application class fails with an actionable message;
- root `opal` still does not load Data or YAML-specific adapter code.

Declare the extension with generic Application autoconfiguration priority
chosen to run before infrastructure that may resolve DataSource. Record and
test the numeric priority rather than relying on type-name order.

## Task 2: Parse Configuration

**Files**

- Create: `src/opal/autoconfig/data/configuration.cr`
- Create: `spec/data_autoconfig_spec.cr`

Parse once during extension configure:

- `database.url` is mandatory and must be String;
- URI scheme `sqlite3` selects `LF::Data::Dialects::SQLite`;
- unsupported scheme is a typed ConfigurationError;
- `database.migrations.run_on_startup` defaults to false and must be Bool;
- existing URI query parameters remain untouched for `crystal-db` pool options.

Do not duplicate pool settings into new YAML keys in v1.

Wrap malformed adapter configuration in `ConfigurationError` and preserve its
cause. Missing-driver, pool, connection, and DB-open failures propagate
unchanged so callers retain their original driver/`DB::Error` types. Messages
created by Opal never include the URL or its credentials; messages originating
inside a concrete driver are not rewritten by the adapter.

Do not add a runtime mutable dialect registry. The adapter uses a compile-time
generated scheme switch containing only concrete dialect entrypoints it
explicitly requires. Adding PostgreSQL later changes this adapter package, not
Data core.

## Task 3: Register And Own DataSource

Extension configure:

1. resolves `LF::ConfigService`;
2. parses Data configuration;
3. opens `DataSource`;
4. registers a singleton bean factory returning that exact instance;
5. resolves the bean once to prove registration;
6. marks configure complete.

Extension stop:

- is idempotent;
- closes the owned datasource;
- handles configure failure where no datasource exists;
- never asks DI to destroy the same resource a second time.

Tests verify the registered instance identity, real SQLite query, close after
runtime shutdown, and cleanup after partial configure failure.

## Task 4: Integrate Startup Migrations

When `run_on_startup` is false:

- do not resolve `MigrationSet`;
- bootstrap succeeds with no MigrationSet bean.

When true:

1. resolve exactly one `MigrationSet` by type from ApplicationContext;
2. translate missing/ambiguous bean errors to Data ConfigurationError while
   preserving their causes;
3. run migrations after DataSource registration and before configure returns;
4. fail and clean up the datasource if migration fails;
5. do not return ApplicationRuntime until migrations are complete.

Test empty set, successful migration, already-applied startup, missing set,
ambiguous sets, and failing migration.

## Task 5: Verify Extension Ordering With HTTP

**Files**

- Create: `spec/data_http_lifecycle_spec.cr`

Build an Application with both markers and a controller using DataSource.
Start a request that blocks after entering request scope. Trigger runtime
shutdown and verify:

1. HTTP stops accepting new requests;
2. active request can still query the database;
3. request exits and request scope closes;
4. HTTP extension stops;
5. Data extension closes datasource;
6. remaining singleton beans are destroyed.

This is the cross-package regression proving reverse extension order.

## Task 6: Boundary Audit

Run:

```bash
rg -n "LF::Application|LF::DI|LF::HTTP|YAML" src/opal/data.cr src/opal/data
rg -n "LF::Data" src/opal/di.cr
```

Both searches must return no forbidden core dependency. References belong only
under `src/opal/autoconfig/data*`.

## Verification

```bash
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec \
  spec/data_autoconfig_compile_spec.cr \
  spec/data_autoconfig_spec.cr \
  spec/data_http_lifecycle_spec.cr \
  spec/http_autoconfig_spec.cr \
  spec/application_autoconfiguration_spec.cr --no-color
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec --no-color
git diff --check
```

Commit as:

```text
feat(data): add application autoconfiguration
```
