# Typed JSON and JSONB columns

## Goal

Persist application-owned Crystal JSON types without exposing driver result
objects or untyped `JSON::Any` at entity boundaries, while retaining native
PostgreSQL JSONB storage and predicates.

## Public contract

```crystal
@[LF::Data::Column(type: :jsonb, codec: EntityChangePayloadCodec)]
property payload : EntityChange::Payload
```

- `type` accepts `:json` or `:jsonb` and selects JSON column semantics.
- `codec` is optional. The default calls the property's generated Crystal JSON
  reader and writer; a custom codec receives a `JSON::PullParser` or
  `JSON::Builder`, never a database driver type.
- A nilable property maps `nil` to SQL `NULL`; a non-nil JSON value may still
  represent the JSON literal `null` when its Crystal type permits it.
- codec and parse failures use typed Data errors and are wrapped with the normal
  entity/property/column `MappingError` context during hydration.
- the existing `converter` hook remains available for non-JSON storage and is
  mutually exclusive with `type` and `codec`.

## Schema and queries

- Add logical `Json` and `Jsonb` schema column types, migration DSL methods,
  PostgreSQL rendering/introspection, SQLite text compatibility, schema diff,
  and migration source generation.
- Add typed PostgreSQL JSONB containment and key predicates. Static queries
  fail at compile time for dialect policies without JSONB operators; dynamic
  queries raise a typed unsupported-query error.
- Keep raw SQL available for the complete PostgreSQL JSON/JSONB operator and
  indexing surface; Opal must not cast JSONB columns to text.

## Validation

- default and custom codec round trips;
- SQL NULL, arrays, nested structures, and union payloads;
- typed encode/decode/storage failures without payload disclosure;
- insert, update, hydration, equality, containment, contained-by, and key
  predicates;
- PostgreSQL schema render/introspection and live round trip;
- SQLite compatibility and full regression suite.
