# Data 04: Compile-Time Entity Mapping

> **For Codex:** REQUIRED SKILLS: `executing-plans`,
> `test-driven-development`, and `verification-before-completion`.

**Goal:** Generate validated persistence metadata, hydration, static CRUD SQL,
and typed field descriptors from ordinary Crystal classes.

**Architecture:** A class explicitly includes `LF::Data::Entity`. Its instance
variables remain the type source of truth. Annotations only override
conventions. No global entity discovery or runtime metadata reflection exists.

**Prerequisite:** Plans 01 and 03 are merged.

---

## Target Entity Contract

```crystal
class Todo
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  @[LF::Data::Column(name: "summary")]
  property title : String

  @[LF::Data::Column(ignore: true)]
  getter display_label : String

  def initialize(@title : String)
    @id = nil
    @display_label = title
  end
end
```

`Todo.new` creates a new domain object. Generated hydration restores persisted
state without invoking that constructor.

## Task 1: Define Mapping Annotations

**Files**

- Create: `src/opal/data/entity.cr`
- Create: `src/opal/data/metadata.cr`
- Modify: `src/opal/data.cr`
- Create: `spec/data/entity_compile_spec.cr`
- Create: `spec/fixtures/data/entities/valid_generated_id.cr`
- Create: `spec/fixtures/data/entities/valid_assigned_id.cr`

Define:

- `LF::Data::Entity` module;
- `LF::Data::Table`;
- `LF::Data::Column`;
- `LF::Data::Id`;
- `LF::Data::Version`.

`Entity` installs generated methods in the including class using a local
`macro finished`. Do not use `Object.all_subclasses` or an entity registry.

## Task 2: Validate Entity Shape At Compile Time

**Fixture files**

- `struct_entity.cr`
- `missing_id.cr`
- `multiple_ids.cr`
- `duplicate_columns.cr`
- `invalid_generated_id.cr`
- `invalid_version_type.cr`
- `writable_version.cr`
- `unsupported_direct_type.cr`
- `invalid_table_name.cr`
- `invalid_column_name.cr`

Implement and test validation in this order:

1. including type must be a class/reference type;
2. exactly one non-ignored ID exists;
3. effective table/column names are non-empty and contain no NUL;
4. effective persistent columns are unique;
5. generated ID is `Int32?` or `Int64?`;
6. assigned ID is non-nil and dumpable;
7. version is one non-nil `Int64` ivar with no public setter;
8. direct fields resolve to portable `DB::Any`;
9. ignored fields are excluded from all persistence metadata.

Every error names the entity and offending field/column. Test message fragments,
not complete compiler output.

## Task 3: Generate Deterministic Names And Metadata

**Files**

- Create: `spec/data/entity_metadata_spec.cr`

Conventions:

- use the unqualified type name for the table;
- convert CamelCase/acronym boundaries with the same deterministic snake-case
  algorithm used by DI service names;
- do not pluralize;
- use ivar name as default column name;
- preserve declaration order for selected and written columns.

Generate a typed metadata surface used internally by generic manager methods.
It exposes table, ID, optional version, persistent columns, and static SQL
fragments without runtime `Hash(String, ...)` lookup.

Tests cover `Todo`, acronym names, namespaced entities, explicit names, ignored
fields, nilable fields, and stable declaration order.

## Task 4: Add Per-Field Converters

**Files**

- Create: `src/opal/data/converter.cr`
- Create: `spec/data/converter_spec.cr`
- Create: `spec/fixtures/data/entities/invalid_converter.cr`

Converter protocol:

```crystal
def self.load(result : DB::ResultSet) : T
def self.dump(value : T) : DB::Any
```

Generated code handles nil before invoking the converter. Converter methods
receive non-nil property values. Compile a real call to both methods so a wrong
signature is a compile-time error.

Test UUID-as-string, enum-as-string, nilable converted values, load failure,
dump failure, and absence of a global registry.

## Task 5: Generate Hydration

**Files**

- Create: `src/opal/data/hydrator.cr`
- Create: `spec/data/entity_hydration_spec.cr`

Generate an internal result-set constructor following Crystal serialization
patterns:

1. allocate the entity;
2. read selected columns by effective name;
3. apply direct reads or converters;
4. assign all persistent ivars;
5. invoke no public domain constructor.

Entity loading is strict. Missing, unexpected, null-for-non-null, and
incompatible columns raise `LF::Data::MappingError` with entity, property,
column, and original cause.

Test a constructor that raises if called to prove hydration bypasses it.

## Task 6: Generate Static CRUD SQL

**Files**

- Create: `spec/data/entity_sql_spec.cr`

Generate constants for:

- full selected column list;
- `SELECT ... WHERE id = ?`;
- INSERT excluding generated ID and ignored fields;
- UPDATE of all writable non-ID/non-version fields;
- DELETE by ID.

All identifiers go through the dialect at use time. Static metadata stores
identifier components and operation templates; runtime must not rediscover
fields. Version predicates are added in Plan 07.

Generated ID and version writers are private persistence methods callable only
through generated generic code, not public domain API.

## Task 7: Generate Typed Field Descriptors

**Files**

- Create: `src/opal/data/query/field.cr`
- Create: `spec/data/query/field_compile_spec.cr`

Generate `Todo::Fields.id`, `title`, and other non-ignored fields. A descriptor
retains entity type, property type, stored type, column, and converter. At this
stage test only construction and typed dump behavior; expression methods arrive
in Plan 06.

## Verification

```bash
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec \
  spec/data/entity_compile_spec.cr \
  spec/data/entity_metadata_spec.cr \
  spec/data/converter_spec.cr \
  spec/data/entity_hydration_spec.cr \
  spec/data/entity_sql_spec.cr \
  spec/data/query/field_compile_spec.cr --no-color
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec --no-color
git diff --check
```

Inspect compiled code or macro expansion for one fixture and confirm there is
no global entity list or runtime field scan.

Commit as:

```text
feat(data): add compile-time entity mapping
```
