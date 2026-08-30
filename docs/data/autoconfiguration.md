# Data Autoconfiguration

Applications opt in explicitly and still load their concrete driver:

```crystal
require "opal"
require "opal/autoconfig/data"
require "sqlite3"

@[LF::ApplicationConfiguration]
class DataConfiguration
  @[LF::DI::Bean]
  def migration_set : LF::Data::MigrationSet
    TodoMigrations.build
  end
end

@[LF::Application]
@[LF::AutoConfig::Data]
class TodoApplication
end
```

```yaml
database:
  url: sqlite3://./todo.db
  migrations:
    run_on_startup: true
```

`database.url` is required. The adapter selects SQLite from the `sqlite3`
scheme, opens one DataSource, registers that exact instance as a singleton, and
owns its close. Startup migrations default to `false`; when enabled, exactly
one `MigrationSet` bean must exist and finishes before bootstrap returns.

Invalid adapter configuration raises
`LF::Data::AutoConfig::ConfigurationError`. Missing-driver, pool, connection,
and DB-open failures propagate unchanged. Opal-created error messages never
include the database URL.

With HTTP enabled, shutdown drains HTTP first, closes Data second, and destroys
remaining DI singletons last.
