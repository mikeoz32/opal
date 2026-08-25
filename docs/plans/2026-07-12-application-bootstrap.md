# Compile-Time Application Layer Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use `executing-plans` to implement this plan task-by-task.

**Goal:** Replace the proposed subclass-based application bootstrap with the accepted compile-time `@[LF::Application]` model, backed by `LF::ApplicationRuntime`, while preserving standalone DI and current HTTP behavior.

**Architecture:** `LF::Application` becomes an annotation. Crystal macros identify one application class and all `@[LF::ApplicationConfiguration]` classes, validate application metadata, generate configuration adapters, and emit deterministic bootstrap registration code. `LF::ApplicationRuntime` owns a root `DefaultContainer`, presents a narrow typed-resolution facade, and coordinates application-level failure/closure semantics; `LF::DI` retains every bean, scope, lifecycle, and dependency-resolution responsibility.

**Tech Stack:** Crystal, Crystal annotations/macros, Crystal Spec, existing `LF::DI`, standard `Process.run` for compiler-fixture specs, existing SQLite example dependencies.

---

## Scope Guardrails

- Do not change router matching, `LF::HTTP::Controller`, HTTP server lifecycle, or
  request-scope ownership.
- Do not add database abstractions, configuration binding, profiles, conditions,
  eager/lazy bean policy, or DI lifecycle features.
- Do not expose `ApplicationRuntime#context`; only add the smallest typed public
  DI resolver required by the runtime facade.
- Keep `LF::DI::DefaultContainer` usable directly and keep its
  explicit `register` ordering untouched.
- Each task starts with a focused failing test, then the smallest production
  change, then focused and full-suite verification. Commit only green steps.

## Baseline

Before Task 1, run:

```bash
crystal spec
crystal run examples/todo_api_sqlite/src/todo_api_sqlite_example.cr
```

The second command is a manual smoke test; stop it after confirming the server
starts. Do not include generated SQLite databases or compiled binaries in git.
Record the actual spec count rather than retaining the stale count in the root
README.

### Task 1: Establish application compile-fixture coverage

**Files:**
- Create: `spec/application_compile_spec.cr`
- Create: `spec/fixtures/application/standalone_di.cr`

**Step 1: Write failing compiler-fixture helpers.**

Add a spec helper that invokes:

```crystal
Process.run(
  "crystal",
  ["build", "--no-codegen", fixture_path],
  output: output,
  error: error
)
```

The helper must return exit status and captured stderr. Use `--no-codegen` so
fixtures validate macro expansion without leaving binaries. Keep fixtures as
separate executables because a compile-time error cannot be asserted inside the
main spec compilation unit.

**Step 2: Add the first green assertion.**

Prove the harness can compile a standalone executable that creates an
`LF::DI::DefaultContainer` and has no application marker. This
baseline verifies the fixture mechanism without depending on the new API.

**Step 3: Run the focused compiler spec.**

```bash
crystal spec spec/application_compile_spec.cr
```

Expected: PASS. The task deliberately tests only existing standalone DI
compatibility so the harness can be committed without carrying a red suite.

**Step 4: Commit only the fixture harness if it is independently green.**

Use: `test: add application compiler fixture harness`.

### Task 2: Add application configuration metadata without changing DI behavior

**Files:**
- Modify: `src/opal/di.cr`
- Modify: `spec/opal_spec.cr`
- Modify: `spec/application_spec.cr`
- Create: `spec/fixtures/application/invalid_configuration_constructor.cr`

**Step 1: Write failing DI-focused specs.**

Define an `@[LF::ApplicationConfiguration]` class that has a
`@[LF::DI::Bean]` factory but does **not** include
`LF::DI::BeanConfiguration`. Prove that registration makes the factory
available. Add a configuration whose zero-argument construction is impossible
and a compiler fixture expecting a clear failure.

Add a regression spec proving ordinary explicit
`include LF::DI::BeanConfiguration` and `context.register(config)` still work
in caller-defined order. This is the compatibility boundary.

**Step 2: Implement the smallest compile-time configuration adapter.**

Add `LF::ApplicationConfiguration` metadata that accepts an optional named `priority`
value (default `0`), plus macro support
that emits the same `configure(ctx)` factory registration generated today by
`BeanConfiguration`. Do not duplicate or change factory resolution, duplicate
bean detection, scope handling, or lifecycle code.

The implementation must make the annotated path self-sufficient. Retain
`BeanConfiguration` for standalone/manual registrations during the migration.
If an annotated class supplies a compatible explicit `configure`, document and
test whether it is rejected or treated as the advanced/manual path; choose one
behavior and keep it deterministic rather than generating two methods.

**Step 3: Verify focused DI and compiler tests.**

```bash
crystal spec spec/opal_spec.cr
crystal spec spec/application_compile_spec.cr
```

**Step 4: Commit.**

Use: `feat(di): add configuration annotation`.

### Task 3: Expose the minimal typed resolver required by the runtime facade

**Files:**
- Modify: `src/opal/di.cr`
- Modify: `spec/opal_spec.cr`

**Step 1: Write failing specs next to current DI resolution specs.**

Add public API coverage for:

```crystal
context.resolve(UniqueService)
context.resolve("unique_service", UniqueService)
```

The type-only overload must preserve current behavior: unique type resolves,
zero candidates raise `LF::DI::BeanNotFoundError`, and multiple candidates raise
`LF::DI::AmbiguousBeanError`. The name-and-type overload must preserve existing
`BeanTypeMismatchError` behavior. Do not test name-first dependency fallback
here; it is already owned by `resolve_dependency` and must not change.

**Step 2: Implement only public delegation.**

Expose a public type-only resolver that calls the existing protected type
lookup. Reuse existing `get_bean(name, Type)` or add a naming-compatible
overload only if required for the planned facade. No new maps, normalization,
or resolution path is allowed.

**Step 3: Verify.**

```bash
crystal spec spec/opal_spec.cr
```

**Step 4: Commit.**

Use: `feat(di): expose typed bean resolver`.

### Task 4: Replace the old application class with marker metadata and generated entrypoints

**Files:**
- Modify: `src/opal/application.cr`
- Modify: `src/opal.cr` only if require ordering needs adjustment
- Replace: `spec/application_spec.cr`
- Modify: `spec/application_compile_spec.cr`
- Create: `spec/fixtures/application/valid_single_app.cr`
- Create: `spec/fixtures/application/no_app_marker.cr`
- Create: `spec/fixtures/application/multiple_app_markers.cr`
- Create: `spec/fixtures/application/app_with_context_argument.cr`
- Create: `spec/fixtures/application/app_with_required_constructor.cr`

**Step 1: Write failing runtime API specs.**

Use one fixture application:

```crystal
@[LF::Application]
class ApplicationSpecApp
  @[LF::DI::Bean]
  def application_spec_value : ApplicationSpecValue
    ApplicationSpecValue.new("configured")
  end
end
```

Prove that `ApplicationSpecApp.bootstrap` returns
`LF::ApplicationRuntime`, its typed `resolve` returns the bean declared on the
application class, and the runtime has no public raw-context API. The latter is
enforced by the negative compiler fixture rather than runtime reflection.

Extend the compiler fixtures to prove that one annotated app compiles, no marker
still compiles, two markers fail with a stable actionable message, passing a
context to `App.bootstrap` fails, and an app class requiring constructor
arguments fails because it also serves as a configuration provider.

**Step 2: Implement the type split.**

Replace the current `class LF::Application` with the annotation declaration
and introduce `LF::ApplicationRuntime`. Generate class methods only on the
single annotated application class. The generated `bootstrap` must allocate a
fresh root `DefaultContainer`; do not accept an injected context in
the public method.

The application class must participate in the same generated DI configuration
path as `@[LF::ApplicationConfiguration]` classes. Do not require `include
BeanConfiguration` or a second configuration class for it.

**Step 3: Verify.**

```bash
crystal spec spec/application_spec.cr
crystal spec spec/application_compile_spec.cr
```

**Step 4: Commit.**

Use: `feat(application): add generated bootstrap entrypoints`.

### Task 5: Implement deterministic configuration discovery and application metadata validation

**Files:**
- Modify: `src/opal/application.cr`
- Modify: `spec/application_spec.cr`
- Modify: `spec/application_compile_spec.cr`
- Create: `spec/fixtures/application/invalid_configuration_priority.cr`

**Step 1: Add RED discovery tests.**

Create configurations with priorities `20`, `0`, `0`, and `-10`. Have their
factory registration append to a test-only trace and assert automatic order:

```text
priority 20 -> priority 0 / alphabetically first -> priority 0 / alphabetically second -> priority -10
```

Add a spec that proves:

- all annotated application configurations are included automatically;
- the application class configuration is included automatically and its
  `@[LF::Application(priority: ...)]` value participates in the same order;
- `LF::DI::ServiceConfiguration` is registered before application
  configurations, so an `@[LF::DI::Service]` can consume an application bean;
- configuration provider instances are not resolvable as DI beans.

**Step 2: Implement compile-time discovery.**

Use Crystal macro expansion over known subclasses/types and annotations. Build
the sorted registration sequence at compilation, then emit direct
`context.register(Config.new)` calls. Do not build a runtime registry or inspect
types while bootstrapping.

Validate application markers as a set: zero markers are valid, one marker emits
entrypoints, and more than one marker fails. Validate configuration priority
shape and zero-argument provider construction at compile time with messages
naming the offending class and required correction.

**Step 3: Run verification.**

```bash
crystal spec spec/application_spec.cr
crystal spec spec/application_compile_spec.cr
crystal spec
```

**Step 4: Commit.**

Use: `feat(application): discover configurations at compile time`.

### Task 6: Add runtime state, bootstrap cleanup, and typed application errors

**Files:**
- Modify: `src/opal/application.cr`
- Modify: `spec/application_spec.cr`

**Step 1: Write RED lifecycle/error specs.**

Cover each observable state transition:

- `shutdown` closes a live runtime and destroys a resolved disposable singleton;
- `resolve` after shutdown raises `ApplicationRuntime::ClosedError`;
- calling `shutdown` twice raises `ApplicationRuntime::AlreadyClosedError`;
- if root DI shutdown raises `LF::DI::BeanDestructionError`, the runtime is still
  closed and later resolution raises `ClosedError`;
- a configuration-registration failure re-raises the original DI error and
  never returns a runtime;
- a partial bootstrap test helper creates a disposable bean before a later
  registration failure, proving bootstrap calls root shutdown during unwind.

The partial-bootstrap helper may use the existing manual `BeanConfiguration`
extension path only inside the spec. It must not become a second public
application bootstrap API.

**Step 2: Implement state and error types.**

Define the application-owned hierarchy under `LF::ApplicationRuntime`, because
Crystal annotations cannot contain nested types:

```crystal
class LF::ApplicationRuntime::Error < Exception; end
class LF::ApplicationRuntime::ClosedError < Error; end
class LF::ApplicationRuntime::AlreadyClosedError < Error; end
```

Guard facade methods with an open-state check. In `shutdown`, set the closed
state in an `ensure` path so DI cleanup errors do not leave a usable-looking
runtime. In bootstrap, clean up the root context on registration failure and
re-raise the original exception. Preserve the original bootstrap error if its
cleanup also fails; document that cleanup failure is not wrapped in this path.

**Step 3: Verify.**

```bash
crystal spec spec/application_spec.cr
crystal spec
```

**Step 4: Commit.**

Use: `feat(application): enforce runtime lifecycle`.

### Task 7: Implement `run` result and dual-failure semantics

**Files:**
- Modify: `src/opal/application.cr`
- Modify: `spec/application_spec.cr`

**Step 1: Add RED run specs.**

Add these cases:

- a successful block returns its exact value and the resolved disposable is
  destroyed before `run` returns;
- a failing block with successful shutdown re-raises that exact block error;
- a successful block with failing shutdown re-raises the DI destruction error;
- a failing block and failing shutdown raise
  `ApplicationRuntime::RunError` whose `block_error` and `shutdown_error`
  expose the original exceptions;
- after any `run` outcome, no runtime remains usable through the yielded
  reference.

Use dedicated exception classes in the spec rather than asserting fragile
string-only behavior.

**Step 2: Implement the smallest control flow.**

Keep `run` as a generic block method. Capture a block failure, always attempt
shutdown, and construct `RunError` only when both phases fail. `RunError` must
retain typed fields and a concise diagnostic message; it must not convert DI
errors into strings.

**Step 3: Verify.**

```bash
crystal spec spec/application_spec.cr
crystal spec
```

**Step 4: Commit.**

Use: `feat(application): add run lifecycle semantics`.

### Task 8: Add and verify example applications

**Files:**
- Create: `examples/application_bootstrap_example.cr`
- Modify: `README.md`
- Modify: `examples/todo_api_sqlite/README.md`
- Modify: `examples/todo_api_sqlite/src/todo_api_sqlite_example.cr` only for
  documentation-aligned DI cleanup; do not migrate its HTTP bootstrap

**Step 1: Add a minimal bootstrap example.**

Create an executable example with one `@[LF::Application]` class, one bean
factory declared on that class, one `@[LF::ApplicationConfiguration]` class, one
`@[LF::DI::Service]`, and `App.run` resolving the service. It must demonstrate
that no manual `add_bean`, manual configuration registration, or raw root
context is required.

**Step 2: Preserve the Todo API's explicit HTTP boundary.**

The SQLite Todo API currently needs direct root-context access to create a
request child scope and assign `HTTP::Server::Context#state`. Application
runtime intentionally hides that context, and HTTP integration is a non-goal
of this ADR. Therefore do not force this example through `ApplicationRuntime`
or expose context solely for it.

Review the example so that:

- `TodoRepository` contains query logic only and never creates schema;
- database creation/schema setup remains in the database resource/configuration
  path;
- services remain annotation-discovered and no manual `add_bean` is introduced;
- startup/shutdown behavior stays explicit and correct.

Document that the example deliberately demonstrates standalone DI plus explicit
HTTP request scopes, while the new minimal example demonstrates application
bootstrap.

**Step 3: Execute smoke checks.**

```bash
crystal run examples/application_bootstrap_example.cr
cd examples/todo_api_sqlite && shards install && crystal run src/todo_api_sqlite_example.cr
```

For Todo, issue `GET /todos` and `POST /todos` with `curl`, then stop the
server. Verify `todo.db` remains ignored and no process is left running.

**Step 4: Commit.**

Use: `docs: add application bootstrap example`.

### Task 9: Publish the API contract and regression evidence

**Files:**
- Modify: `README.md`
- Modify: `docs/adr/README.md`
- Modify: `docs/adr/ADR-0002-application-bootstrap-layer.md` only if code
  reality requires a clarification
- Modify: `docs/plans/2026-07-12-application-bootstrap.md` only to record any
  intentional deviation

**Step 1: Update public documentation.**

Document two valid entry styles side by side:

1. standalone DI with explicit root context and request scopes;
2. `@[LF::Application]` with generated `bootstrap`/`run` and typed resolution.

List the exact ownership boundaries: DI owns beans/scopes/lifecycle; Application
owns root-context creation and application closure; HTTP integration remains
explicit. Include configuration priority rules, zero-argument provider rule,
and the application error contract. Do not advertise database/configuration
features that do not exist.

**Step 2: Run complete verification.**

```bash
crystal spec
crystal spec spec/application_compile_spec.cr
crystal run examples/application_bootstrap_example.cr
```

Run the Todo integration smoke test again, inspect `git status --short`, and
remove only generated ignored artifacts if present. Confirm no source or
documentation refers to the removed subclass-based `LF::Application` runtime.

**Step 3: Commit.**

Use: `docs: document application layer`.

## Final Acceptance Checklist

- One annotated app generates only `App.bootstrap` and `App.run`; more than one
  fails during compilation; no marker leaves a normal Crystal executable.
- Application configuration and DI configuration are discovered at compile time,
  sorted deterministically, and carry no runtime scanning cost.
- Application class bean factories, annotated configuration bean factories, and
  autowired services work together.
- The runtime cannot receive or expose a raw context through its public API.
- Resolution after close and repeated shutdown have typed application errors.
- Bootstrap cleanup, normal `run`, block failure, shutdown failure, and dual
  failure behavior all have focused regression coverage.
- Existing standalone DI, router, `APIRoute`, request scope, and lifecycle specs
  remain green.
- The new bootstrap example runs; the SQLite HTTP Todo example still serves its
  endpoints using explicit HTTP/request-scope wiring.
- No generated databases, binaries, vendored dependencies, or server processes
  remain after verification.
