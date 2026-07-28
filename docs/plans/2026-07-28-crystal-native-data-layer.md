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

| Order | Plan | Deliverable | Depends on |
| --- | --- | --- | --- |
| 01 | [Foundation and test infrastructure](data/01-foundation-and-test-infrastructure.md) | dependencies, opt-in entrypoint, shared DB test harness | ADR-0005 |
| 02 | [Conditional Application autoconfiguration](data/02-conditional-application-autoconfiguration.md) | generic marker-driven extension installation | 01 |
| 03 | [DataSource, dialect, and observability](data/03-datasource-dialect-observability.md) | transaction/resource foundation | 01 |
| 04 | [Compile-time entity mapping](data/04-compile-time-entity-mapping.md) | entity metadata, hydration, converters, static SQL | 03 |
| 05 | [EntityManager and Unit of Work](data/05-entity-manager-unit-of-work.md) | identity map, states, queued writes, flush | 04 |
| 06 | [Typed query and bulk DML](data/06-typed-query-and-bulk-dml.md) | typed expressions, SELECT, bulk UPDATE/DELETE | 05 |
| 07 | [Optimistic locking](data/07-optimistic-locking.md) | version-aware UPDATE/DELETE and stale detection | 05 |
| 08 | [Forward-only migrations](data/08-forward-only-migrations.md) | migration set, schema editor, history runner | 03 |
| 09 | [Data autoconfiguration](data/09-data-autoconfiguration.md) | YAML-driven DataSource and startup migration integration | 02, 03, 08 |
| 10 | [Todo example and public documentation](data/10-todo-example-and-documentation.md) | end-to-end example, process checks, user guides | 04-09 |

Plans 02 and 03 may be implemented in parallel after Plan 01 because their
write sets do not overlap except for dependency lockfiles, which Plan 01 owns.
Plans 04 and 08 may be implemented in parallel after Plan 03 because migrations
do not depend on entity mapping. Plans 06 and 07 may be implemented in parallel
after Plan 05. Plan 09 waits for Application autoconfiguration, DataSource, and
migrations. Plan 10 is the integration gate and always runs last.

## Branch And Review Strategy

Each plan uses a branch from the latest merged predecessor:

```text
codex/data-01-foundation
codex/data-02-application-autoconfig
codex/data-03-datasource
codex/data-04-entity-mapping
codex/data-05-unit-of-work
codex/data-06-query
codex/data-07-optimistic-locking
codex/data-08-migrations
codex/data-09-autoconfig
codex/data-10-example-docs
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
- Static CRUD SQL is generated at compile time.
- Driver and SQL failures preserve their original `DB::Error` types.
- Every long-lived resource has explicit ownership and idempotent shutdown.

## Release Gate

After Plan 10, run:

```bash
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec --no-color
shards build
git diff --check
git status --short --branch
```

Then audit every normative ADR-0005 section and confirm deferred features were
not partially introduced: relations, lazy loading, cascades, joins, composite
IDs, inheritance mapping, projections, savepoints, second-level cache,
generated repositories, `attach`, `merge`, and dirty checking.
