# Data 17: Repository And Query Convenience API

> **For Codex:** REQUIRED SKILLS: `executing-plans`,
> `test-driven-development`, and `verification-before-completion`.

**Goal:** Provide optional typed repository conveniences without hiding
transaction boundaries or introducing global persistence state.

**Prerequisite:** Plans 05-07 and 13. Relationships are not required.

## Scope

Repositories are explicit objects constructed with a `DataSource` or
transaction-local `EntityManager`. They delegate to the existing query and
unit-of-work APIs. Convenience methods include typed `find`, `find_by`,
`exists?`, `count`, and pagination. Reads do not open implicit write
transactions or flush automatically.

Do not generate repositories from entities in this plan. Generated repository
implementations, joins, projections, and specification DSLs require separate
decisions.

## Tasks

1. Define typed repository contracts and construction rules.
2. Add convenience methods over existing static/dynamic query paths.
3. Define behavior for pagination, empty results, and terminal operations.
4. Add tests proving no implicit flush and no hidden transaction ownership.
5. Document lifecycle and error propagation.

## Definition Of Done

- Repository methods preserve compile-time entity and ID types.
- All SQL still comes from existing query plans.
- Resource ownership remains explicit.
- Driver errors and transaction errors retain their original types.
- The API is optional and does not alter the EntityManager contract.
