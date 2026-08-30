# Crystal-Native Data Layer Delivery Roadmap

> This document defines delivery order and cross-plan invariants. It is not an
> execution plan. Each linked plan is implemented and reviewed independently.

**Goal:** Deliver ADR-0005 through small, sequential, always-green pull
requests instead of one long-lived database-layer branch.

**Architectural source:** `docs/adr/ADR-0005-crystal-native-data-layer.md`.

## Why The Work Is Split

The feature contains four distinct risk classes:

1. compile-time framework work in Application and entity macros;
2. transaction and object-state correctness in Unit of Work;
3. SQL generation and dialect behavior;
4. operational behavior in migrations, startup, shutdown, and examples.

Combining them would make failures difficult to attribute and would force API
review after too much implementation already depended on it. Every plan below
therefore ends in a usable, documented, fully tested repository state.

## Execution Plans

### V1 delivery

| Order | Plan | Deliverable | Depends on |
| --- | --- | --- | --- |
| 01 | [Foundation and test infrastructure](data/01-foundation-and-test-infrastructure.md) | dependencies, opt-in entrypoint, shared DB test harness | ADR-0005 |
| 02 | [Dialect contract and SQLite](data/02-dialect-contract-and-sqlite.md) | generic compile-time SQL-plan contract and optional SQLite implementation | 01 |
| 03 | [DataSource and observability](data/03-datasource-observability.md) | transaction/resource foundation and listener dispatch | 02 |
| 04 | [Compile-time entity mapping](data/04-compile-time-entity-mapping.md) | entity metadata, hydration, converters, direct bind tuples | 03 |
| 05 | [EntityManager and Unit of Work](data/05-entity-manager-unit-of-work.md) | identity map, states, queued writes, flush | 04 |
| 06 | [Typed query and bulk DML](data/06-typed-query-and-bulk-dml.md) | typed expressions, SELECT, bulk UPDATE/DELETE | 05 |
| 07 | [Optimistic locking](data/07-optimistic-locking.md) | version-aware UPDATE/DELETE and stale detection | 05 |
| 08 | [Forward-only migrations](data/08-forward-only-migrations.md) | schema renderer, migration set, history runner | 02, 03 |
| 09 | [Conditional Application autoconfiguration](data/09-conditional-application-autoconfiguration.md) | generic marker-driven extension installation | 01-08 |
| 10 | [Data autoconfiguration](data/10-data-autoconfiguration.md) | YAML-driven DataSource and startup migration integration | 03, 08, 09 |
| 11 | [Todo example and public documentation](data/11-todo-example-and-documentation.md) | end-to-end example, process checks, user guides | 04-10 |
| 12 | [Data correctness hardening](data/12-data-correctness-hardening.md) | correctness regressions and lifecycle hardening | 01-11 |

Plan 11 is the v1 integration gate. Plan 12 is the final correctness and
release-hardening pass over that complete surface.

### Data expansion roadmap

The following plans extend the initial Data contract. Each remains independently
scoped so release planning can include the capabilities that are ready without
silently pulling in the rest of the roadmap.

| Order | Plan | Deliverable | Depends on |
| --- | --- | --- | --- |
| 13 | [Typed entity IDs](data/13-typed-entity-ids.md) | compile-time ID-safe entity operations | 01-12 |
| 14 | [PostgreSQL dialect](data/14-postgresql-dialect.md) | optional PostgreSQL SQL and schema support | 01-08, 12 |
| 15 | [Dialect-specific migration locks](data/15-dialect-migration-locks.md) | explicit concurrent migration safety | 08, 14 |
| 16 | [Relationships and cascades](data/16-relationships-and-cascades.md) | explicit relationship metadata and flush policies | 04-08, 13-14 |
| 17 | [Repository and query API](data/17-repository-query-api.md) | typed convenience API over existing queries | 05-07, 13 |
| 18 | [Schema diff and migration generation](data/18-schema-diff-and-migration-generation.md) | deterministic schema plans and source generation | 02, 08, 14; extended by 16 |

Plans 01 through 08 deliver a complete standalone Data layer before any
Application integration starts. Within that boundary, Plan 08 depends only on
Dialect and DataSource and may be developed alongside entity mapping and Unit
of Work, but it is merged before Plan 09. Plans 06 and 07 may be developed in
parallel after Plan 05. Plan 09 then adds the generic Application mechanism,
Plan 10 adapts Data to it, and Plan 11 is the final integration gate.
Plan 12 hardens the initial surface. Plans 13 through 18 are sequenced expansion
capabilities; the active release scope decides which of them ship together.

## Branch And Review Strategy

Each plan uses a branch from the latest merged predecessor:

```text
codex/data-01-foundation
codex/data-02-dialects
codex/data-03-datasource
codex/data-04-entity-mapping
codex/data-05-unit-of-work
codex/data-06-query
codex/data-07-optimistic-locking
codex/data-08-migrations
codex/data-09-application-autoconfig
codex/data-10-autoconfig
codex/data-11-example-docs
codex/data-12-correctness-hardening
```

Each branch must be reviewable without uncommitted code from a later plan.
Public APIs introduced by a plan cannot be changed silently in a later plan;
such changes require updating ADR-0005 and the affected plan first.

## Global TDD Rules

Every behavior follows:

1. write one focused failing spec or compile fixture;
2. run it and verify failure is caused by missing behavior;
3. implement the minimum behavior;
4. run the focused spec;
5. run all specs owned by the current plan;
6. refactor while green;
7. run the complete suite and `git diff --check`;
8. commit only a green slice.

Use a shared cache outside the repository:

```bash
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec --no-color
```

Compile-time fixture tests use `crystal build --no-codegen`. Temporary SQLite
files, executables, and server processes live under `/tmp` and are removed in
`ensure` blocks.

## Cross-Plan Invariants

- `src/opal.cr` never requires Data.
- `LF::DI` never references Application, HTTP, or Data.
- Data core never references Application, DI, HTTP, YAML, or a concrete driver.
- SQLite remains a development/example dependency, not a runtime Opal
  dependency.
- No global mutable persistence state is introduced.
- No query performs an implicit flush.
- No entity property mutation executes SQL.
- Static CRUD SQL is produced by the shared compiler and specialized at compile
  time per entity and concrete dialect, using the dialect's static policy.
- Static query SQL is produced by the shared compiler and specialized at
  compile time per entity, concrete dialect, and query-shape type; runtime
  values use generated bind tuples.
- Arbitrary runtime filter structures use only the explicit `DynamicQuery`
  fallback.
- Opal owns no SQL-plan or prepared-statement cache; `crystal-db` owns
  per-connection preparation and caching.
- Driver and SQL failures preserve their original `DB::Error` types.
- Every long-lived resource has explicit ownership and idempotent shutdown.

## Release Gate

For every release candidate, run:

```bash
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec --no-color
shards build
git diff --check
git status --short --branch
```

Then audit every normative ADR-0005 section, confirm that lazy loading remains
absent, and confirm deferred features were not partially introduced: joins,
composite IDs, inheritance mapping, projections, savepoints, second-level
cache, generated repositories, `attach`, `merge`, and dirty checking. Plans
13-18 may add only the explicitly scoped capabilities described in their own
documents.
