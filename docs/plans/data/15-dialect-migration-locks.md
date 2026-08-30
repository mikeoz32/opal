# Data 15: Dialect-Specific Migration Locks

> **For Codex:** REQUIRED SKILLS: `executing-plans`,
> `test-driven-development`, and `verification-before-completion`.

**Goal:** Prevent concurrent migration runners from relying on accidental
database behavior.

**Prerequisite:** Plan 14 and the migration implementation from Plan 08.

## Scope

Add a dialect-owned migration lock contract with explicit capability checks.
PostgreSQL uses an advisory lock scoped to the migration run. SQLite retains
transactional history conflict reconciliation. A dialect that cannot provide a
safe lock or transactional DDL must fail startup rather than silently claim
concurrent migration safety.

`DialectCapability::MigrationLock` means that the dialect provides an explicit
safe coordination strategy; it does not mean every database has an engine lock.
SQLite returns `TransactionalHistoryMigrationLock`, a no-op session object that
names its transactional-DDL plus unique-history-row strategy. PostgreSQL returns
a real session advisory lock. This distinction prevents SQLite reconciliation
from being described as a lock it does not acquire.

The lock must be acquired and released on the same connection. Release is
idempotent and runs on every failure path. Lock identifiers are deterministic
and namespaced for the application/database.

## Tasks

1. Add lock capability and typed lock errors to the dialect contract.
2. Implement SQLite and PostgreSQL strategies.
3. Wrap migration planning/execution in the lock boundary.
4. Test concurrent runners, lock timeout, release after failure, and shutdown.
5. Preserve immutable migration descriptors and unknown-applied-version checks.

## Definition Of Done

- Concurrent migration tests are deterministic for each supported dialect.
- No broad exception is treated as a migration conflict.
- Non-transactional unsupported dialects fail before executing migrations.
- Lock cleanup errors preserve the primary migration error.
