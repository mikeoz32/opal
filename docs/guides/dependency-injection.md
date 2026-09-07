# Dependency injection

Opal DI is a small, explicit container with deterministic scope ownership.
It is not a service locator for request data: inject application dependencies
through constructors and receive HTTP values as action parameters.

## Register services

Mark constructor-injectable classes with `@[LF::DI::Service]`, then register
the generated configuration once in the root container:

```crystal
--8<-- "examples/documentation/dependency_injection_guide.cr:service"
```

By default a bean is a singleton. A provider can choose a scope explicitly:

```crystal
--8<-- "examples/documentation/dependency_injection_guide.cr:provider"
```

## Scope ownership

`RequestScopeHandler` opens `request` around a regular HTTP request.
`WebSocketScopeHandler` holds a WebSocket scope for the accepted connection.
Both deterministically destroy disposable scoped instances when their owner
exits.

```crystal
--8<-- "examples/documentation/dependency_injection_guide.cr:handlers"
```

Keep `WebSocketScopeHandler` before `RequestScopeHandler`: an accepted upgrade
owns its WebSocket scope for the connection lifetime, while ordinary requests
continue through the shorter request scope.

`LF::DI::Disposable#destroy` is the correct place to unsubscribe, close a
connection-scoped resource, or stop a worker tied to that scope.

## Constraints that prevent lifecycle bugs

- A child scope cannot add beans.
- A singleton cannot resolve a shorter-lived bean.
- A closed scope cannot resolve new dependencies.
- Type-based lookup rejects ambiguous registrations rather than picking one
  arbitrarily.

Read the [DI lifecycle ADR](../adr/ADR-0001-di-bean-lifecycle-callbacks.md)
before introducing a custom scope or application extension.
