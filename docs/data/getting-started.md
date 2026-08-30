# Data Getting Started

Opal Data is opt-in. Add Opal and the concrete database driver to the
application shard:

```yaml
dependencies:
  opal:
    github: mikeoz32/opal
  sqlite3:
    github: crystal-lang/crystal-sqlite3
```

Load the Data API, the selected dialect, and the driver:

```crystal
require "opal/data"
require "opal/data/dialects/sqlite"
require "sqlite3"
```

For PostgreSQL, use the optional dialect and `crystal-pg` driver instead:

```yaml
dependencies:
  opal:
    github: mikeoz32/opal
  pg:
    github: will/crystal-pg
```

```crystal
require "opal/data"
require "opal/data/dialects/postgresql"
require "pg"
```

`DataSource.open` owns the `DB::Database` it creates and closes it when the
source closes. A source constructed from an existing `DB::Database` borrows it
by default:

```crystal
source = LF::Data::DataSource.open(
  "sqlite3://./app.db",
  dialect: LF::Data::Dialects::SQLite.new
)

source.transaction do |manager|
  manager.query(Todo).to_a
end

source.close
```

Every `EntityManager` is transaction-local. Never store or inject one beyond
the `DataSource#transaction` block. See
[transactions and repositories](transactions-and-repositories.md) for the
composition pattern and [autoconfiguration](autoconfiguration.md) when an
`LF::Application` should own the source.

## Deliberate v1 boundaries

V1 does not provide relationship mapping, joins, projections, composite IDs,
inheritance mapping, generated repositories, automatic timestamps, dirty
checking, `attach`/`merge`, savepoints, transparent retries, schema
synchronization, migration rollback, or a second-level cache.
Additional dialects beyond SQLite and PostgreSQL are post-v1 packages. These
features must be added through explicit contracts rather than partially
inferred behavior.

Lazy loading, proxy objects, and implicit relationship queries are permanent
non-goals. Relationship APIs must keep database access explicit.
