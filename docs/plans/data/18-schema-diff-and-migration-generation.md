# Data 18: Schema Diff And Migration Generation

> **For Codex:** REQUIRED SKILLS: `executing-plans`,
> `test-driven-development`, and `verification-before-completion`.

**Goal:** Compare declared schema metadata with an inspected database schema
and generate explicit migration plans.

**Prerequisite:** Plans 02, 08, and 14. Relationship-derived schema metadata
from Plan 16 extends this contract but does not block an explicit schema model.

## Scope

Schema diff is a read/plan operation. It produces typed operations and does
not mutate the database automatically. Migration source generation is an
explicit developer command or library API. Destructive operations require an
explicit opt-in marker and must be visible in the generated plan.

Entity mapping remains separate from schema authority unless an application
explicitly supplies a schema model. No startup auto-sync is introduced.
The initial generator compares portable tables, columns, constraints, and
indexes already represented by the schema DSL. Relationship declarations from
Plan 16 may later populate that model; they do not create a global registry.

## Tasks

1. Define inspected schema records and dialect introspection contracts.
2. Compare tables, columns, indexes, constraints, and relationships.
3. Produce deterministic typed operation plans.
4. Detect ambiguous renames and destructive changes.
5. Generate migration source with stable ordering and readable diagnostics.
6. Test SQLite and PostgreSQL differences, empty diffs, destructive guards,
   and generated-source compatibility with `MigrationRunner`.

## Definition Of Done

- Identical schemas produce an empty diff.
- Diff output is deterministic and dialect-aware.
- Destructive changes never execute implicitly.
- Ambiguous changes fail rather than guessing.
- Generated migrations pass the existing MigrationRunner contract.
