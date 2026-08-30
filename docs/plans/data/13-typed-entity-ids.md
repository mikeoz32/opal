# Data 13: Typed Entity IDs

> **For Codex:** REQUIRED SKILLS: `executing-plans`,
> `test-driven-development`, and `verification-before-completion`.

**Goal:** Make entity lookup and identity operations use the ID type declared by
the entity at compile time.

**Prerequisite:** Plans 01-12.

## Scope

The generated entity metadata must expose its declared ID type without adding a
runtime metadata registry. `find`, `delete`, identity-map keys, and generated
CRUD paths must reject a value of the wrong type during compilation. Nilability
of generated IDs remains an entity lifecycle concern and must not make lookup
IDs implicitly nilable.

Do not introduce composite IDs, polymorphic IDs, runtime coercion, or a public
repository abstraction in this plan.

## Tasks

1. Generate a typed ID descriptor and typed manager operations.
2. Preserve converter behavior while validating the application-facing ID type.
3. Add compile-error fixtures for wrong ID types, nil IDs, and cross-entity IDs.
4. Add runtime regression coverage for assigned and generated IDs.
5. Update the public API documentation and ADR terminology.

## Definition Of Done

- Wrong ID types fail at compile time.
- Correct IDs work for `find`, `delete`, update scheduling, and identity lookup.
- No runtime registry or reflection is added.
- Existing entity and query specs remain green.
- The generated code remains specialized per entity.

## Verification

Run the focused compile fixtures, all Data specs, the root suite, and
`git diff --check`.
