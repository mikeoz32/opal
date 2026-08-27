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

The first version must choose and document ownership for each cascade action:
database-level foreign-key cascade, EntityManager-level cascade, or rejection.
It must not add lazy loading, proxy objects, implicit queries, dirty checking,
joins, or global relationship registries.

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

