# Dependency injection

Opal DI is a small, explicit container with deterministic scope ownership.
It is not a service locator for request data: inject application dependencies
through constructors and receive HTTP values as action parameters.

## Register services

Mark constructor-injectable classes with `@[LF::DI::Service]`, then register
the generated configuration once in the root container:

```crystal
@[LF::DI::Service]
class Clock
  def now : Time
    Time.utc
  end
end

root = LF::DI::DefaultContainer.new
root.register(LF::DI::ServiceConfiguration.new)
```

By default a bean is a singleton. A provider can choose a scope explicitly:

```crystal
class AppBeans
  include LF::DI::BeanConfiguration

  @[LF::DI::Bean(name: "request_id", scope: "request")]
  def request_id : String
    UUID.random.to_s
  end
end
```

## Scope ownership

`RequestScopeHandler` opens `request` around a regular HTTP request.
`WebSocketScopeHandler` holds a WebSocket scope for the accepted connection.
Both deterministically destroy disposable scoped instances when their owner
exits.

```crystal
server = HTTP::Server.new([
  LF::HTTP::DI::RequestScopeHandler.new(root),
  LF::HTTP::DI::WebSocketScopeHandler.new(root),
  app,
])
```

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
