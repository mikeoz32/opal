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
- entity-declared lookup ID enforcement and typed delete-by-ID scheduling;
- end-to-end SQLite Data and Todo examples with process-level verification.

### Changed

- minimum supported Crystal version is 1.21.0;
- framework package boundaries keep HTTP, Application, DI, and Data optional.
