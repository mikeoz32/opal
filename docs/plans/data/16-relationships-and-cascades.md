# Data 16: Relationships And Cascades

> **For Codex:** REQUIRED SKILLS: `executing-plans`,
> `test-driven-development`, and `verification-before-completion`.

**Goal:** Add explicit relationship metadata and predictable cascading while
keeping persistence operations visible and transaction-local.

**Prerequisite:** Plans 04-08, 13, and 14.

## Scope

Support explicit `belongs_to`, `has_many`, and `has_one` declarations generated
at compile time. Relationship metadata is not inferred from arbitrary fields.
Foreign-key DDL and EntityManager operation ordering must be separate concerns.

The relationship API must choose and document ownership for each cascade action:
database-level foreign-key cascade, EntityManager-level cascade, or rejection.
Lazy loading, proxy objects, and implicit relationship queries are permanent
non-goals. This plan also does not add dirty checking, joins, or global
relationship registries.

## Contract

- Navigation properties use `BelongsTo`, `HasMany`, or `HasOne` and explicitly
  name their scalar `foreign_key` property.
- Hydration sets singular relations to nil and collections to empty. Loading
  and graph attachment are application/repository operations.
- `cascade_persist` enrolls new in-memory targets. Already managed targets
  require their own explicit `persist` to schedule an update.
- `cascade_remove` is owner-side only for `has_many` and `has_one`, and applies
  only to targets already loaded and managed by the same transaction.
- `belongs_to` remove cascade and orphan removal are rejected. Collection
  mutation alone never schedules persistence.
- A relation descriptor may add an explicit schema-model foreign key;
  `has_one` also adds uniqueness. No database `ON DELETE` action is inferred.
- Flush topologically orders the queued in-memory graph and rejects dependency
  cycles before executing its first queued statement.

## Tasks

1. Define relationship declarations and compile-time validation.
2. Generate foreign-key metadata and schema operations.
3. Build dependency-aware insert/delete ordering with cycle detection.
4. Implement explicit cascade policies for persist/remove.
5. Test orphan behavior, cycles, missing targets, rollback, and optimistic
   locking interactions.

## Definition Of Done

- Relationship structure is compile-time validated.
- Flush order is deterministic and transaction-local.
- Cascade behavior is explicit in the API and docs.
- Cycles and unsupported cascade combinations fail with typed errors.
- Existing non-relational entities behave identically.
