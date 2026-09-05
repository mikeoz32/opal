# HTTP controllers and policies

`LF::HTTP::Controller` is the high-level routing API. It discovers route
annotations at compile time, creates a request-scoped controller, binds input,
and serializes an action result.

## Route and input binding

```crystal
class ProjectsApi
  include LF::HTTP::Controller

  @[LF::HTTP::Controller::Get("/projects/:id")]
  def show(id : UUID, request : HTTP::Request)
    {id: id, request_id: request.headers["X-Request-Id"]?}
  end
end
```

Supported scalar path/query types and one `JSON::Serializable` body are bound
before the action runs. Return a serializable model for JSON or an
`LF::HTTP::Response` when status, headers, or body are explicit.

## Policies are annotations on the controller

Guards, pipes, interceptors, and filters are reusable DI beans. Attach them
where they apply; a separate policy holder is not required for controller-level
policy.

```crystal
@[LF::HTTP::UseGuards(AuthenticatedGuard)]
@[LF::HTTP::UseInterceptors(RequestTiming)]
class ProjectsApi
  include LF::HTTP::Controller

  @[LF::HTTP::Controller::Post("/projects")]
  @[LF::HTTP::UsePipes(TrimStrings)]
  @[LF::HTTP::UseFilters(ApiErrorFilter)]
  def create(payload : CreateProject)
    # ...
  end
end
```

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
