# Data 18: Schema Diff And Migration Generation

> **For Codex:** REQUIRED SKILLS: `executing-plans`,
> `test-driven-development`, and `verification-before-completion`.

**Goal:** Compare declared schema metadata with an inspected database schema
and generate explicit migration plans.

**Prerequisite:** Plans 02, 08, 14, and the relationship metadata from Plan 16.

## Scope

Schema diff is a read/plan operation. It produces typed operations and does
not mutate the database automatically. Migration source generation is an
explicit developer command or library API. Destructive operations require an
explicit opt-in marker and must be visible in the generated plan.

Entity mapping remains separate from schema authority unless an application
explicitly supplies a schema model. No startup auto-sync is introduced.

## Tasks

1. Define inspected schema records and dialect introspection contracts.
2. Compare tables, columns, indexes, constraints, and relationships.
3. Produce deterministic typed operation plans.
4. Detect ambiguous renames and destructive changes.
5. Generate migration source with stable ordering and readable diagnostics.
6. Test SQLite and PostgreSQL differences, empty diffs, and rollback plans.

## Definition Of Done

- Identical schemas produce an empty diff.
- Diff output is deterministic and dialect-aware.
- Destructive changes never execute implicitly.
- Ambiguous changes fail rather than guessing.
- Generated migrations pass the existing MigrationRunner contract.

