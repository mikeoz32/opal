# Package Boundaries Refactor Implementation Plan

> **For Codex:** REQUIRED SUB-SKILLS: Use `systematic-debugging`, `test-driven-development`, and `verification-before-completion` task-by-task.

**Goal:** Restore strict DI, Application, Routing, and HTTP boundaries while fixing lifecycle leaks and preserving request-time performance.

**Architecture:** DI owns bean definitions, resolution, scopes, and lifecycle only. Application owns compile-time application/configuration discovery and root-container orchestration. HTTP owns routing, binding, responses, and an optional DI request-scope adapter; the trie becomes an internal routing detail.

**Tech Stack:** Crystal 1.18+, Crystal macros/annotations, Crystal Spec, standard `HTTP::Handler` stack.

---

### Task 1: Remove application discovery from DI

**Files:** `src/opal/di.cr`, `spec/opal_spec.cr`, `spec/application_compile_spec.cr`, `spec/fixtures/application/*`

1. Remove the experimental `LF::DI::Configuration`, global configuration scanner, generic `register`, and their tests.
2. Restore typed bean-configuration registration.
3. Keep and test public typed `resolve` because bean resolution is DI-owned.
4. Run focused DI and full specs.

### Task 2: Fix DI lifecycle semantics and names

**Files:** `src/opal/di.cr`, `spec/opal_spec.cr`, examples and README references

1. Add failing tests for prototype destroy, root exit, closed scope reuse, shutdown reuse, reverse destroy order, and destroy-error aggregation.
2. Track every owned instance independently from the singleton/scoped cache.
3. Make scope/root closure deterministic; repeated DI close remains idempotent, but resolution/mutation after close raises `ContextClosedError`.
4. Remove duplicate `exit`/`shutdown` cleanup loops.
5. Replace application-oriented DI names with `BeanConfiguration`, `ServiceConfiguration`, `Container`, and `DefaultContainer`.

### Task 3: Split HTTP parameter binding from DI

**Files:** `src/opal.cr`, new `src/opal/http/*`, `spec/opal_spec.cr`

1. Add failing JSON-body-without-DI and scalar-binding-without-DI tests.
2. Replace `Hash#to_t` with `LF::HTTP::ParameterDecoder`.
3. Resolve path/query/body before attempting DI resolution.
4. Replace concrete `context.dependency_scope` coupling with an optional DI resolver slot owned by the HTTP integration.
5. Move repeated request-scope middleware into `LF::HTTP::DI::RequestScopeHandler`.

### Task 4: Split the HTTP package

**Files:** `src/opal.cr`, new `src/opal/http/{errors,response,router,api_route,app}.cr`

1. Make `src/opal.cr` a require-only entrypoint.
2. Move errors, responses, routing, controller macro, and app handler into focused files.
3. Rename `LFApi` to `LF::HTTP::App`, `APIRoute` to `LF::HTTP::Controller`, `HTTPException` to `LF::HTTP::Error`, and `Response#call` to `write_to`.
4. Remove redundant exception branches and extract shared HTTP spec helpers.

### Task 5: Make trie an internal routing component

**Files:** `src/opal/trie.cr`, HTTP router specs

1. Move it under `LF::Routing::Trie`.
2. Remove public mutable node state, duplicate child storage, dead priority state, and debug output.
3. Dispatch directly from the router without allocating `LF::Route` per request.
4. Keep existing matching regression coverage green.

### Task 6: Implement the accepted Application layer

**Files:** `src/opal/application.cr`, `spec/application_spec.cr`, compiler fixtures

1. Add RED compiler/runtime tests for zero/one/multiple application markers, generated `bootstrap/run`, configuration priority, typed resolution, and hidden root context.
2. Define `@[LF::Application]`, `@[LF::ApplicationConfiguration]`, and `LF::ApplicationRuntime`.
3. Generate application/configuration bean registration in the Application package using `LF::DI::Bean` metadata; DI must not discover application metadata.
4. Implement atomic bootstrap, closed runtime semantics, result-preserving `run`, and dual-failure `RunError`.

### Task 7: Update examples and documentation

**Files:** `README.md`, `docs/adr/*`, `examples/*`

1. Update ADR-0002 so application configuration is application-owned.
2. Mark ADR-0001 implementation gaps resolved or explicitly deferred.
3. Migrate examples to the renamed DI/HTTP APIs.
4. Add an Application example and use the shared request-scope handler in HTTP examples.
5. Keep the SQLite schema in the database resource boundary, not the repository.

### Task 8: Final verification

1. Run `crystal spec` with a writable cache.
2. Compile all examples.
3. Run and curl the SQLite Todo API.
4. Verify no generated binaries/databases/processes remain.
5. Inspect the final diff for old names, mixed dependencies, and duplicated macro/cleanup logic.
