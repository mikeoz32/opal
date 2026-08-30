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

`@[Column]` can rename a column, ignore an application-only property, or select
a stateless converter. Mapping validates IDs, versions, duplicate columns,
supported stored types, and converter calls at compile time.

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
