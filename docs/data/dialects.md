# Data Dialects

Data core depends only on `LF::Data::Dialect`. A concrete dialect owns SQL
quoting, placeholders, static plan policy, generated-key behavior, schema
rendering, connection initialization, and capability reporting.

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
generated IDs, native boolean/timestamp/byte types, transactional DDL, and a
database/application-namespaced advisory migration lock. Requiring the dialect
does not load or register `crystal-pg`; the application owns that choice.

Unsupported operations fail before partial execution with typed Opal errors.
Driver, pool, connection, and SQL failures retain their original `DB::Error`
types.

MySQL and any additional dialects remain future packages. Adding a dialect
must not add `case dialect` branches, driver dependencies, or mutable
registries to Data core.
