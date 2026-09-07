# Data Dialects

Data core depends only on `LF::Data::Dialect`. A concrete dialect owns SQL
quoting, placeholders, static plan policy, generated-key behavior, schema
rendering and introspection, connection initialization, and capability
reporting.

SQLite is loaded separately:

```crystal
require "opal/data"
require "opal/data/dialects/sqlite"
require "sqlite3"
```

The dialect entrypoint does not load the `sqlite3` driver. Applications choose
their driver explicitly. Database URL query parameters are passed unchanged to
`crystal-db`, so pool configuration stays in the URL rather than new Opal YAML
keys.

PostgreSQL follows the same boundary:

```crystal
require "opal/data"
require "opal/data/dialects/postgresql"
require "pg"
```

The PostgreSQL dialect uses numbered `$1` binds, `INSERT ... RETURNING` for
generated IDs, native boolean/timestamp/byte/JSON/JSONB types, typed JSONB
containment and key predicates, transactional DDL, and a
database/application-namespaced advisory migration lock. Requiring the dialect
does not load or register `crystal-pg`; the application owns that choice.

SQLite and PostgreSQL both advertise `SchemaInspection`. Introspection
normalizes only the portable schema types and artifacts that Opal can represent;
vendor-only types and expression or partial indexes fail with
`SchemaInspectionError` rather than being silently omitted.

SQLite renders logical JSON and JSONB columns as `TEXT` and supports typed
entity round trips through the same codecs. It does not emulate PostgreSQL
JSONB query operators. Static use is rejected by the SQLite query policy and
dynamic use raises `UnsupportedQueryOperatorError`.

Unsupported operations fail before partial execution with typed Opal errors.
Driver, pool, connection, and SQL failures retain their original `DB::Error`
types.

MySQL and any additional dialects remain future packages. Adding a dialect
must not add `case dialect` branches, driver dependencies, or mutable
registries to Data core.
