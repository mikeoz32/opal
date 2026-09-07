module LF
  module Data
    # Overrides the table name for an `Entity`. Without it, Opal converts the
    # unqualified class name to snake case.
    annotation Table
    end

    # Configures one persisted property. Supported named arguments are `name`,
    # `ignore`, and a stateless `converter` type.
    annotation Column
    end

    # Marks the entity's single primary-key property. Set `generated: true` only
    # on an `Int32?` or `Int64?` property populated after insertion.
    annotation Id
    end

    # Marks the optional optimistic-lock property. It must be a getter-only,
    # non-nil `Int64` with a zero default.
    annotation Version
    end

    # Declares a nilable child-to-parent navigation property. `foreign_key` names
    # the scalar property stored on this entity; loading always remains explicit.
    annotation BelongsTo
    end

    # Declares a nilable one-to-one child navigation property. The target owns
    # the named scalar `foreign_key` and must declare the inverse `BelongsTo`.
    annotation HasOne
    end

    # Declares an `Array(Target)` child collection. The target owns the named
    # scalar `foreign_key` and must declare the inverse `BelongsTo`.
    annotation HasMany
    end
  end
end
