# ADR-0001: DI Bean Lifecycle Callbacks (Init/Destroy)

- Status: Proposed
- Date: 2026-05-24
- Deciders: Opal maintainers
- Related: `LF::DI` container, `LF::APIRoute` integration

## Context

`LF::DI` already supports bean registration, scoping, autowiring, and typed runtime errors.  
What is missing is a lifecycle model for resource-like beans (`DB::Database`, clients, producers, pools), especially around:

- initialization timing
- deterministic cleanup
- scoped shutdown behavior
- graceful process shutdown

Without lifecycle callbacks, examples and integrations must manually manage resource creation and cleanup outside of the container contract.

## Decision

We will add bean lifecycle callbacks in DI v1 with the following contract.

### 1) Lifecycle phases

- `init`
- `destroy`

No extra phases in v1.

### 2) How callbacks are declared

Beans define lifecycle behavior themselves via:

- interface-based callbacks
- annotation-based callbacks

No external lifecycle callback procs for v1.

### 3) Singleton init policy

- Container-level default init mode (`lazy` or `eager`)
- Per-bean init mode override

### 4) Destroy behavior

- Singleton destroy runs automatically via `at_exit`
- Singleton destroy can also be triggered manually via explicit container close/exit API
- Destroy order is `LIFO` by creation order
- Destroy errors are logged and cleanup continues (`best effort`)

### 5) Child/request scopes

- `destroy` is called on `scope.exit`
- Prototype instances created in scope are tracked and destroyed on `scope.exit`

### 6) Conflict and failure handling

- If both interface and annotation define the same lifecycle phase for one bean: configuration error
- `init` errors fail bean creation and are raised to caller
- Type/name resolution behavior remains `name-first`, then `type-fallback` with ambiguity errors

## Detailed Requirements

1. Singleton lifecycle works with lazy/eager default and per-bean override.
2. `at_exit` triggers singleton destroy callbacks in `LIFO` order.
3. Manual close is idempotent.
4. Child scope exit triggers destroy for scoped/prototype instances created in that scope.
5. Lifecycle declaration conflicts are rejected deterministically.
6. `init` failure is a hard failure for bean creation.
7. `destroy` failure does not stop subsequent bean destruction.

## Proposed API Shape (v1)

### Interfaces

- `LF::DI::LifecycleInit` with `init : Nil`
- `LF::DI::LifecycleDestroy` with `destroy : Nil`

### Annotations

- `@[LF::DI::PostConstruct]`
- `@[LF::DI::PreDestroy]`

### Container config/options

- default init mode at container level (`lazy`/`eager`)
- per-bean init mode override (`default`/`lazy`/`eager`)

### Errors

Add lifecycle-specific errors:

- `LF::DI::LifecycleConfigurationError`
- `LF::DI::BeanInitError`
- `LF::DI::BeanDestroyError`

Existing DI errors (`BeanNotFoundError`, `BeanTypeMismatchError`, `DuplicateBeanError`, `ScopeMismatchError`, `AmbiguousBeanError`) remain in use.

## Consequences

### Positive

- Clear resource lifecycle contract in DI
- Fewer manual cleanup patterns in application code
- Better safety for DB/client integrations
- More predictable shutdown and scoped cleanup behavior

### Trade-offs

- Slightly more DI complexity (tracking + callback invocation)
- Extra validation paths around callback declarations
- Additional test surface (lifecycle state transitions and shutdown behavior)

## Implementation Plan (High-Level)

1. Implement interface-based lifecycle callbacks (`init`/`destroy`) with tests.
2. Add container-level init mode and per-bean override.
3. Add destroy orchestration (`LIFO`, best effort, `at_exit`, manual close).
4. Add scope-level destroy for scoped/prototype instances.
5. Add annotation-based lifecycle callbacks.
6. Add conflict validation and lifecycle-specific error classes.
7. Update docs/examples to demonstrate resource lifecycle in DI.

## Testing Strategy

- Unit tests for lifecycle callback discovery, invocation order, and error handling.
- Scope tests for `scope.exit` cleanup semantics.
- Shutdown tests for `at_exit` and manual close idempotency.
- Integration tests with a resource-like bean (e.g. SQLite DB wrapper).
