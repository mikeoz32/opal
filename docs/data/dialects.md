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

Unsupported operations fail before partial execution with typed Opal errors.
Driver, pool, connection, and SQL failures retain their original `DB::Error`
types.

PostgreSQL and MySQL are not part of Data v1. Adding a dialect must not add
`case dialect` branches, driver dependencies, or mutable registries to Data
core.
