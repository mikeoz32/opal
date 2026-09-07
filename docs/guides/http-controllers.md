# HTTP controllers and policies

`LF::HTTP::Controller` is the high-level routing API. It discovers route
annotations at compile time, creates a request-scoped controller, binds input,
and serializes an action result.

## Route and input binding

```crystal
--8<-- "examples/documentation/http_controllers_guide.cr:binding"
```

Supported scalar path/query types and one `JSON::Serializable` body are bound
before the action runs. Return a serializable model for JSON or an
`LF::HTTP::Response` when status, headers, or body are explicit.

## Policies are annotations on the controller

Guards, pipes, interceptors, and filters are reusable DI beans. Attach them
where they apply; a separate policy holder is not required for controller-level
policy.

```crystal
--8<-- "examples/documentation/http_controllers_guide.cr:policies"
```

This complete example registers every policy as a generated DI service. The
`name` action argument comes from the query string, its parameter-level pipe
trims it, and the returned `ProjectView` is serialized as JSON.

The execution order is global → controller → action → parameter. Guards run
before request binding. Interceptors wrap the action and unwind in reverse.
Filters search from action to controller to global policy owners.

!!! warning "WebSocket actions"

    Guards run before a WebSocket upgrade. Pipes, interceptors, and filters
    retain their HTTP action meaning; validate individual WebSocket messages in
    the connection handler.

The root README contains a complete four-policy example; the
[controller pipeline ADR](../adr/ADR-0008-http-controller-execution-pipeline.md)
is the authoritative execution contract.
