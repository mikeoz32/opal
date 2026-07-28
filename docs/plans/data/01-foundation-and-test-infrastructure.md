# Data 01: Foundation And Test Infrastructure

> **For Codex:** REQUIRED SKILLS: `executing-plans`,
> `test-driven-development`, and `verification-before-completion`.

**Goal:** Add the generic database dependency, an opt-in Data entrypoint, and
reusable SQLite/compile-fixture test support without implementing persistence.

**Architecture:** Opal may depend on `crystal-db`, but `require "opal"` must not
load `LF::Data`. SQLite is available only to specs and examples.

**Tech Stack:** Crystal, crystal-db 0.14.x, crystal-sqlite3, Crystal Spec.

**Prerequisite:** ADR-0005 is accepted and the pre-change suite reports 171
examples with zero failures.

---

## Task 1: Add The Generic Database Dependency

**Files**

- Modify: `shard.yml`
- Modify: `shard.lock`

Add:

```yaml
dependencies:
  db:
    github: crystal-lang/crystal-db
    version: ~> 0.14

development_dependencies:
  sqlite3:
    github: crystal-lang/crystal-sqlite3
```

**TDD steps**

1. Add a temporary compile fixture that requires `db`.
2. Run it before dependency installation and verify that the dependency is
   unavailable from a clean root shard installation.
3. Add the dependency declarations.
4. Run `shards install`.
5. Verify `shard.lock` pins compatible `db` and `sqlite3` releases.
6. Re-run the fixture and complete suite.

Do not add SQLite to production dependencies. Do not copy vendored `lib/`
directories from the example into the root shard.

## Task 2: Add The Opt-In Entry Point

**Files**

- Create: `src/opal/data.cr`
- Create: `spec/data/entrypoint_spec.cr`
- Create: `spec/fixtures/data/opal_without_data.cr`
- Create: `spec/fixtures/data/data_entrypoint.cr`

Initially `src/opal/data.cr` requires `db` and declares an empty `LF::Data`
namespace. Later plans add internal requires here.

Required compile behaviors:

```crystal
# Must compile and must not expose LF::Data.
require "../../../src/opal"

# Must compile without requiring sqlite3.
require "../../../src/opal/data"
LF::Data
```

The first fixture must fail if it references `LF::Data`, proving the root
entrypoint does not leak the optional module. The second fixture must compile
with `--no-codegen`.

Do not modify `src/opal.cr`.

## Task 3: Add Shared Compile-Fixture Support

**Files**

- Create: `spec/data/spec_helper.cr`
- Create: `spec/data/support/compile_fixture.cr`
- Modify: `spec/data/entrypoint_spec.cr`

Provide one helper returning:

```crystal
NamedTuple(status: Process::Status, output: String, error: String)
```

It runs:

```text
crystal build --no-codegen <fixture>
```

with `CRYSTAL_CACHE_DIR` defaulting to `/tmp/opal-crystal-cache`. Keep this
helper inside Data specs; do not refactor existing Application compile specs in
this plan.

Tests verify successful and unsuccessful fixtures capture stderr and exit
status correctly.

## Task 4: Add Isolated SQLite Support

**Files**

- Create: `spec/data/support/sqlite_database.cr`
- Create: `spec/data/support/sql_recorder.cr`
- Create: `spec/data/support/temp_path.cr`
- Create: `spec/data/support/sqlite_database_spec.cr`

Provide helpers for:

- a fresh `sqlite3::memory:` `DB::Database`;
- a unique `/tmp/opal-data-<pid>-<random>.db` path;
- cleanup in `ensure`, including `-wal` and `-shm` sidecars;
- a SQL recorder usable by later listeners;
- deterministic table existence and row-count assertions.

No helper may retain a database between examples. Every opened database is
closed even when the example raises.

## Verification

Run:

```bash
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec \
  spec/data/entrypoint_spec.cr \
  spec/data/support/sqlite_database_spec.cr --no-color
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec --no-color
git diff --check
```

Expected result:

- all old 171 examples still pass;
- new foundation examples pass;
- `src/opal.cr` is unchanged;
- no database or binary exists under the repository.

Commit green slices as:

```text
build: add crystal-db development foundation
test(data): add isolated database test support
```

Stop for review before Plan 02.
