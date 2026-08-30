# Schema Diff And Migration Generation

Opal can inspect a live SQLite or PostgreSQL database, compare it with an
explicit application-owned schema model, and generate a normal forward-only
Crystal migration. It never changes the database during inspection or source
generation.

Declare the schema authority separately from entity mapping:

```crystal
schema_model = LF::Data::Schema::Model.build do |schema|
  schema.table("projects") do |table|
    table.generated_id("id")
    table.string("name", null: false)
    table.bool("active", null: false, default: true)
    table.index("idx_projects_active", "active")
  end
end
```

Create a generator from an open datasource and review the typed plan before
writing its source:

```crystal
generator = LF::Data::Schema::MigrationGenerator.new(source)
plan = generator.plan(schema_model)

plan.steps.each do |step|
  puts "#{step.safety}: #{step.description}"
end

unless plan.empty?
  source_code = generator.generate(
    schema_model,
    version: 2026083001_i64,
    name: "create_projects",
    class_name: "CreateProjects"
  )
  File.write("src/migrations/2026083001_create_projects.cr", source_code)
end
```

The generated class implements `LF::Data::Migration` and runs through the
existing `MigrationRunner`, including transactions, history, and migration
locks. Version, migration name, class name, and output path remain explicit
developer choices.

## Safety Rules

- Inspection and diff planning are read-only. There is no startup auto-sync.
- `_lf_migrations` is unmanaged by default. Additional tables may be excluded
  with `DiffOptions#ignore_table`.
- Table and column renames require `rename_table` or `rename_column` hints; the
  differ never guesses from similar names.
- Dropping tables or indexes remains visible as destructive `DiffStep` values.
  Source generation refuses them unless `allow_destructive: true` is passed
  after review.
- Removed columns, changed column definitions, constraint changes, and cyclic
  dependencies produce diagnostics and require an explicit handwritten
  migration. The generator does not emit a partial migration while diagnostics
  remain.
- Entity annotations are not schema authority. Applications opt in by supplying
  a `Schema::Model`; automatic entity-to-schema inference remains unsupported.

Relationship descriptors can add a known foreign key to that explicit model
without turning entities into schema authority:

```crystal
schema.table("tasks") do |table|
  table.generated_id("id")
  table.int64("project_id", null: false)
  table.foreign_key(Task::Relations.project)
end
```

The table and columns are still declared by the application. A `has_one`
descriptor additionally adds a unique constraint to its foreign-key column.
See [relationships and cascades](relationships.md) for ownership rules.

Rename hints are applied before comparison:

```crystal
options = LF::Data::Schema::DiffOptions.new
  .rename_table("legacy_projects", "projects")
  .rename_column("projects", "label", "name")

plan = generator.plan(schema_model, options)
```

SQLite normalizes its storage affinities when comparing portable logical types,
while PostgreSQL retains distinct boolean, integer, timestamp, and byte types.
Non-portable database types, expression/partial indexes, and vendor-specific
defaults fail inspection unless their whole table is explicitly unmanaged.
