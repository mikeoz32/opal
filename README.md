# Opal

Opal is a modular HTTP, dependency injection, and application bootstrap toolkit for Crystal.

It is built on top of Crystal's standard `HTTP::Handler` stack and focuses on:

- trie-based path matching
- path parameter extraction
- method-aware routing with `404` / `405` handling
- lightweight API handlers via `LF::HTTP::Controller`
- scoped dependency injection with deterministic lifecycle cleanup
- optional compile-time application bootstrap

## Status

The routing, HTTP binding, DI lifecycle, and Application compiler contracts are covered by specs in this repository.

## Installation

Add this to your application's `shard.yml`:

```yaml
dependencies:
  opal:
    github: your-username/opal
```

Then install shards:

```bash
shards install
```

## Core API

Opal exposes four independent layers:

1. `LF::HTTP::Router`
   Low-level router with explicit handlers.

2. `LF::HTTP::App`
   `HTTP::Handler` wrapper around a router with consistent HTTP error handling.

3. `LF::HTTP::Controller`
   Macro-based API route definition with parameter binding and optional DI lookup.

4. `@[LF::Application]` and `LF::ApplicationRuntime`
   Optional compile-time application assembly and root-container ownership.

## Basic Router

```crystal
require "opal"

router = LF::HTTP::Router.new

router.get("/") do |ctx, _params|
  ctx.response.print "Welcome"
end

router.get("/users/:id") do |ctx, params|
  ctx.response.print "User #{params["id"]}"
end

router.post("/users") do |ctx, _params|
  ctx.response.status = HTTP::Status::CREATED
  ctx.response.print "created"
end

server = HTTP::Server.new([
  HTTP::LogHandler.new,
  router,
])

server.bind_tcp(8080)
server.listen
```

## HTTP App

`LF::HTTP::App` wraps `LF::HTTP::Router` and converts `LF::HTTP::BadRequest`, `LF::HTTP::NotFound`, and other internal exceptions into HTTP responses.

```crystal
require "opal"

app = LF::HTTP::App.new do |router|
  router.get("/hello/:name") do |ctx, params|
    ctx.response.print "Hello, #{params["name"]}"
  end
end

server = HTTP::Server.new([
  HTTP::LogHandler.new,
  app,
])

server.bind_tcp(8080)
server.listen
```

## HTTP Controller

`LF::HTTP::Controller` is the higher-level API surface. It supports:

- route params
- query params
- `HTTP::Request`
- DI lookup from `context.dependency_scope`
- JSON body parsing for `JSON::Serializable`
- `LF::HTTP::Response` return types such as `LF::HTTP::JSONResponse`

### Example

```crystal
require "opal"

class UserPayload
  include JSON::Serializable

  property name : String
end

class UserView
  include JSON::Serializable

  property id : Int32
  property name : String

  def initialize(@id : Int32, @name : String)
  end
end

class UsersApi
  include LF::HTTP::Controller

  @[LF::HTTP::Controller::Get("/users/:id")]
  def show(id : Int32)
    LF::HTTP::JSONResponse.create(UserView.new(id, "User #{id}"))
  end

  @[LF::HTTP::Controller::Post("/users")]
  def create(payload : UserPayload)
    LF::HTTP::JSONResponse.create(UserView.new(1, payload.name))
  end
end

app = LF::HTTP::App.new do |router|
  UsersApi.new.setup_routes(router)
end
```

## DI Container

The built-in DI container lives under `LF::DI`.

### Registering beans manually

```crystal
root = LF::DI::DefaultContainer.new

root.add_bean(name: "greeting_service", scope: "request", type: GreetingService) do |_ctx|
  GreetingService.new("Hello")
end
```

### Request scope

Service arguments require `context.dependency_scope` to contain an `LF::DI::Container`. Path, query, request, and JSON body arguments do not require DI.

A built-in handler creates and closes a child scope around each request:

```crystal
server = HTTP::Server.new([
  LF::HTTP::DI::RequestScopeHandler.new(root),
  app,
])
```

### Autowired services

You can also declare services with `@[LF::DI::Service]` and register `LF::DI::ServiceConfiguration`.

Autowiring currently works like this:

1. resolve by argument name and type
2. if not found, fall back to type lookup
3. if multiple beans of the same type exist, raise `LF::DI::AmbiguousBeanError`

### Lifecycle callbacks

Beans can opt into lifecycle hooks by implementing:

- `LF::DI::Initializable#after_properties_set`
- `LF::DI::Disposable#destroy`

Lifecycle behavior:

- init runs after instance creation and before cache commit
- init runs exactly once per created instance
- child-owned disposable instances are destroyed on `scope.exit`
- root-owned disposable singletons are destroyed on `root.shutdown`
- destroy order is reverse creation order within the owning context

Example:

```crystal
class RequestResource
  include LF::DI::Initializable
  include LF::DI::Disposable

  def after_properties_set : Nil
    puts "resource ready"
  end

  def destroy : Nil
    puts "resource cleaned up"
  end
end

root = LF::DI::DefaultContainer.new

root.add_bean(name: "request_resource", scope: "request", type: RequestResource) do |_ctx|
  RequestResource.new
end

scope = root.enter_scope("request")
scope.get_bean("request_resource", RequestResource)
scope.exit

root.shutdown
```

## Application Bootstrap

Application bootstrap is optional. Standalone DI and HTTP usage remain valid without an application marker.

```crystal
@[LF::ApplicationConfiguration(priority: 10)]
class Infrastructure
  @[LF::DI::Bean]
  def clock : Clock
    Clock.new
  end
end

@[LF::Application]
class TodoApplication
end

TodoApplication.run do |application|
  application.resolve(TodoService).start
end
```

The generated `bootstrap` method owns a fresh root container. `LF::ApplicationRuntime` exposes only `resolve(Type)`, `resolve(name, Type)`, `shutdown`, and state/error contracts; it does not expose the mutable container.

## Integration Pattern

Opal is easiest to integrate anywhere that already uses Crystal's `HTTP::Handler` chain.

That includes:

- plain `HTTP::Server`
- custom middleware stacks
- frameworks that expose handler-compatible extension points

Minimal pattern:

```crystal
server = HTTP::Server.new([
  HTTP::LogHandler.new,
  SomeMiddleware.new,
  app_or_router,
])
```

Where `app_or_router` can be either:

- `LF::HTTP::Router`
- `LF::HTTP::App`

## Examples

The repository includes these examples:

- [examples/router_example.cr](examples/router_example.cr)
  Basic router + JSON response example.

- [examples/api_route_di_example.cr](examples/api_route_di_example.cr)
  `LF::HTTP::Controller` with request-scoped DI and `LF::HTTP::JSONResponse`.

- [examples/di_lifecycle_example.cr](examples/di_lifecycle_example.cr)
  Standalone lifecycle example showing `after_properties_set`, `exit`, and `shutdown`.

- [examples/handler_stack_example.cr](examples/handler_stack_example.cr)
  Integration through a normal `HTTP::Handler` middleware stack.

- [examples/application_bootstrap_example.cr](examples/application_bootstrap_example.cr)
  Compile-time application discovery, generated entrypoints, and typed resolution.

- [examples/todo_api_sqlite](examples/todo_api_sqlite/README.md)
  Standalone Todo API project with SQLite persistence.

Run them with:

```bash
crystal run examples/router_example.cr
crystal run examples/api_route_di_example.cr
crystal run examples/handler_stack_example.cr
crystal run examples/application_bootstrap_example.cr
```

For the standalone SQLite Todo API example, run commands from `examples/todo_api_sqlite`:

```bash
shards install
crystal run src/todo_api_sqlite_example.cr
```

## Route Matching Rules

Current route behavior covered by specs:

- exact matches win over parameter matches
- root path `/` is supported
- trailing slashes are normalized
- repeated slashes are normalized
- extra path segments do not match
- multiple HTTP methods may share the same path
- unsupported methods return `405 Method Not Allowed`

## Responses

Opal includes these response helpers:

- `LF::HTTP::TextResponse.create("...")`
- `LF::HTTP::JSONResponse.create(serializable_object)`

If a controller method returns an `LF::HTTP::Response`, Opal writes it to the HTTP response.

## Error Types

### HTTP layer

- `LF::HTTP::BadRequest`
- `LF::HTTP::NotFound`
- `LF::HTTP::InternalServerError`

### DI layer

- `LF::DI::BeanNotFoundError`
- `LF::DI::BeanTypeMismatchError`
- `LF::DI::DuplicateBeanError`
- `LF::DI::ScopeMismatchError`
- `LF::DI::AmbiguousBeanError`
- `LF::DI::ContextClosedError`

## Testing

Run the full test suite:

```bash
crystal spec
```

## License

See [LICENSE](LICENSE).
