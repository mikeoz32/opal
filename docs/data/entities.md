# Data Entities

Entities are classes with compile-time mapping metadata:

```crystal
@[LF::Data::Table("todos")]
class Todo
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  property title : String

  @[LF::Data::Version]
  getter version : Int64 = 0_i64
end
```

`@[Column]` can rename a column, ignore an application-only property, select a
stateless converter, or declare typed JSON storage. Mapping validates IDs,
versions, duplicate columns, supported stored types, and converter calls at
compile time.

## Typed JSON and JSONB

Use `type: :json` or `type: :jsonb` to keep a concrete Crystal type at the
entity boundary while storing its JSON representation:

```crystal
struct CreatedPayload
  include JSON::Serializable

  getter created_id : String

  def initialize(@created_id : String)
  end
end

struct ArchivedPayload
  include JSON::Serializable

  getter reason : String

  def initialize(@reason : String)
  end
end

alias EntityChangePayload = CreatedPayload | ArchivedPayload

@[LF::Data::Table("entity_changes")]
class EntityChange
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::Column(type: :jsonb)]
  property payload : EntityChangePayload

  @[LF::Data::Column(type: :json)]
  property labels : Array(String)

  @[LF::Data::Column(type: :jsonb)]
  property metadata : Hash(String, String)?

  def initialize(@id, @payload, @labels, @metadata)
  end
end
```

The default codec uses Crystal's `JSON::Serializable` contract. It supports
arrays, nested serializable types, and unions that Crystal can distinguish.
The declared property type is restored during hydration; Opal does not expose
`JSON::Any` or a driver-specific JSON wrapper to the entity.

A nilable property maps Crystal `nil` to SQL `NULL`, and SQL `NULL` back to
Crystal `nil`. This differs from a JSON literal `null`, which remains JSON data
and requires a property type that can decode it.

### Custom codecs

Use `codec:` when the application type does not implement the default JSON
contract or needs a versioned wire representation:

```crystal
module EntityChangePayloadCodec
  def self.load(
    parser : JSON::PullParser,
    type : EntityChangePayload.class,
  ) : EntityChangePayload
    EntityChangePayload.new(parser)
  end

  def self.dump(
    value : EntityChangePayload,
    builder : JSON::Builder,
  ) : Nil
    value.to_json(builder)
  end
end

@[LF::Data::Column(type: :jsonb, codec: EntityChangePayloadCodec)]
property payload : EntityChangePayload
```

Codecs are stateless compile-time references. `load` receives a normalized
`JSON::PullParser`; `dump` writes one JSON value to the provided
`JSON::Builder`. They never depend on PostgreSQL, SQLite, or a database driver.
`load` must consume the complete JSON value; trailing content is rejected.
`codec:` requires `type: :json` or `type: :jsonb`, and cannot be combined with
`converter:`.

Encoding and decoding failures raise `JSONColumnEncodeError` or
`JSONColumnDecodeError`. A driver value that cannot represent JSON raises
`JSONColumnStorageError`. Hydration adds entity, property, and column context
through `MappingError`; error messages do not include the JSON payload.

The declared ID type is also the lookup contract. Assigned IDs use their exact
property type. A generated `Int32?` or `Int64?` property remains nilable only
while the entity is new; `find` and delete-by-ID require non-nil `Int32` or
`Int64` values. Wrong, nilable, and differently typed entity IDs fail during
compilation. ID converters accept the application-facing ID type before the
converted database value becomes an identity-map key.

An EntityManager tracks `New`, `Managed`, `Removed`, and `Detached` states.
`persist` and `remove` only schedule work; transaction completion performs the
remaining `flush`. An explicit `flush` is required when generated IDs or new
versions are needed before the block returns.

Updates write every persistent non-ID/non-version property because v1 has no
dirty snapshots. Optimistic entities use the manager-owned loaded version in
the write predicate and raise `OptimisticLockError` when no row matches.

Persistence annotations do not define HTTP serialization. Prefer dedicated
request and response models when nilable generated IDs or stored converter
types would weaken the external contract.

Navigation properties use separate compile-time relationship annotations and
are never stored as columns. See [relationships and cascades](relationships.md)
for explicit loading, foreign-key metadata, flush ordering, and cascade rules.
