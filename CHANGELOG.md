# Changelog

All notable changes to Opal are documented in this file.

## [Unreleased]

### Added

- compile-time Application bootstrap and conditional autoconfiguration;
- HTTP controller discovery, request-scope DI, graceful request draining, and
  typed configuration;
- opt-in DataSource, entity mapping, transaction-local EntityManager, static
  and dynamic queries, bulk DML, converters, listeners, and optimistic locking;
- SQLite dialect, portable schema operations, forward-only migrations, and
  Data Application autoconfiguration;
- opt-in PostgreSQL dialect with numbered binds, `RETURNING`, native schema
  rendering, and real-service integration coverage;
- connection-pinned migration sessions with PostgreSQL advisory locks and
  explicit SQLite transactional-history coordination;
- explicit SQLite/PostgreSQL schema inspection, deterministic typed diffs, and
  guarded Crystal migration source generation;
- compile-time `belongs_to`, `has_many`, and `has_one` metadata with explicit
  loading, dependency-ordered flushes, and opt-in persist/remove cascades;
- entity-declared lookup ID enforcement and typed delete-by-ID scheduling;
- manager-bound typed repositories with read/write conveniences, bulk builders,
  and composed-query one-based pagination;
- end-to-end SQLite Data and Todo examples with process-level verification;
- bounded transport-aware HTTP drain with typed timeout reporting;
- explicit controller `HEAD` and `OPTIONS` routes, deterministic HTTP 405
  `Allow` metadata, and application error-body mapping;
- optional accessible UI primitives with a precompiled Tailwind theme,
  including dialogs, dropdowns, tabs, toasts, accordions, tooltips, and
  LiveNavigation-aware pagination.

### Changed

- minimum supported Crystal version is 1.21.0;
- framework package boundaries keep HTTP, Application, DI, and Data optional;
- LiveView markup uses upstream `phx-*` bindings directly instead of a custom
  `data-opal-*` binding prefix;
- incomplete extension stops preserve dependent extensions and root DI until a
  safe shutdown retry.
