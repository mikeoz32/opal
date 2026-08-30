# Data 14: PostgreSQL Dialect

> **For Codex:** REQUIRED SKILLS: `executing-plans`,
> `test-driven-development`, and `verification-before-completion`.

**Goal:** Add a PostgreSQL dialect without leaking PostgreSQL behavior into
Data core or changing SQLite semantics.

**Prerequisite:** Plans 01-08 and 12. Plan 13 is recommended but not required.

## Scope

Add an optional dialect and explicit PostgreSQL driver/example dependency. The
dialect owns quoting, placeholders, generated-key syntax, returning behavior,
boolean/timestamp rendering, schema operations, and capability declarations.
Data core must remain driver-neutral.

No live PostgreSQL service is required for the unit suite. SQL rendering and
compile-time specialization must be covered with a recorder/fake connection;
an opt-in integration job may run against a service container.

## Tasks

1. Define the optional PostgreSQL entrypoint and dependency boundary.
2. Implement dialect and schema renderer contracts.
3. Cover static CRUD/query plans and generated keys.
4. Cover migration history timestamps and identifier quoting.
5. Add compatibility tests shared with SQLite.
6. Add an optional CI integration job with a real PostgreSQL service.

## Definition Of Done

- PostgreSQL is opt-in and absent from `require "opal/data"`.
- No `case dialect` branches are added to Data core.
- Static and dynamic SQL use prepared binds.
- Unsupported capabilities fail with typed errors.
- SQLite tests and behavior remain unchanged.

## Verification

Run dialect contract specs, compile-time specialization specs, all Data specs,
and the optional PostgreSQL integration job.
