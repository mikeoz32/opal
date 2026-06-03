# Opal

Opal is a high-performance HTTP router and lightweight API layer for Crystal.

It is built on top of Crystal's standard `HTTP::Handler` stack and focuses on:

- trie-based path matching
- path parameter extraction
- method-aware routing with `404` / `405` handling
- lightweight API handlers via `LF::APIRoute`
- small dependency injection container for request-scoped services

## Status

The router core, `APIRoute`, and DI container are covered by specs in this repository.

Current verified test status:

- `107 examples`
- `0 failures`
- `0 errors`

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

Opal exposes three main layers:

1. `LF::Router`
   Low-level router with explicit handlers.

2. `LF::LFApi`
   `HTTP::Handler` wrapper around a router with consistent HTTP error handling.

3. `LF::APIRoute`
   Macro-based API route definition with parameter binding and optional DI lookup.

## Basic Router

```crystal
require "opal"

router = LF::Router.new

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

## LFApi

`LF::LFApi` wraps `LF::Router` and converts `LF::BadRequest`, `LF::NotFound`, and other internal exceptions into HTTP responses.

```crystal
require "opal"

app = LF::LFApi.new do |router|
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

## APIRoute

`LF::APIRoute` is the higher-level API surface. It supports:

- route params
- query params
- `HTTP::Request`
- DI lookup from `context.state`
- JSON body parsing for `JSON::Serializable`
- `LF::Response` return types such as `LF::JSONResponse`

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
  include LF::APIRoute

  @[LF::APIRoute::Get("/users/:id")]
  def show(id : Int32)
    LF::JSONResponse.create(UserView.new(id, "User #{id}"))
  end

  @[LF::APIRoute::Post("/users")]
  def create(payload : UserPayload)
    LF::JSONResponse.create(UserView.new(1, payload.name))
  end
end

app = LF::LFApi.new do |router|
  UsersApi.new.setup_routes(router)
end
```

## DI Container

The built-in DI container lives under `LF::DI`.

### Registering beans manually

```crystal
root = LF::DI::AnnotationApplicationContext.new

root.add_bean(name: "greeting_service", scope: "request", type: GreetingService) do |_ctx|
  GreetingService.new("Hello")
end
```

### Request scope

`LF::APIRoute` expects `context.state` to contain an `LF::DI::AnnotationApplicationContext`.

A common pattern is to create request-scoped child contexts in middleware:

```crystal
class RequestScopeHandler
  include HTTP::Handler

  def initialize(@root : LF::DI::AnnotationApplicationContext)
  end

  def call(context)
    scope = @root.enter_scope("request")
    context.state = scope
    call_next(context)
  ensure
    scope.exit
  end
end
```

### Autowired services

You can also declare services with `@[LF::DI::Service]` and register `LF::DI::AutowiredApplicationConfig`.

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

root = LF::DI::AnnotationApplicationContext.new

root.add_bean(name: "request_resource", scope: "request", type: RequestResource) do |_ctx|
  RequestResource.new
end

scope = root.enter_scope("request")
scope.get_bean("request_resource", RequestResource)
scope.exit

root.shutdown
```

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

- `LF::Router`
- `LF::LFApi`

## Examples

The repository includes these examples:

- [examples/router_example.cr](/home/mike/opal/examples/router_example.cr)
  Basic router + JSON response example.

- [examples/api_route_di_example.cr](/home/mike/opal/examples/api_route_di_example.cr)
  `APIRoute` with request-scoped DI and `LF::JSONResponse`.

- [examples/di_lifecycle_example.cr](/home/mike/opal/examples/di_lifecycle_example.cr)
  Standalone lifecycle example showing `after_properties_set`, `exit`, and `shutdown`.

- [examples/handler_stack_example.cr](/home/mike/opal/examples/handler_stack_example.cr)
  Integration through a normal `HTTP::Handler` middleware stack.

- [examples/todo_api_sqlite](/home/mike/opal/examples/todo_api_sqlite/README.md)
  Standalone Todo API project with SQLite persistence.

Run them with:

```bash
crystal run examples/router_example.cr
crystal run examples/api_route_di_example.cr
crystal run examples/handler_stack_example.cr
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

- `LF::TextResponse.create("...")`
- `LF::JSONResponse.create(serializable_object)`

If an `APIRoute` method returns an `LF::Response`, Opal writes it to the HTTP response.

## Error Types

### HTTP layer

- `LF::BadRequest`
- `LF::NotFound`
- `LF::InternalServerError`

### DI layer

- `LF::DI::BeanNotFoundError`
- `LF::DI::BeanTypeMismatchError`
- `LF::DI::DuplicateBeanError`
- `LF::DI::ScopeMismatchError`
- `LF::DI::AmbiguousBeanError`

## Testing

Run the full test suite:

```bash
crystal spec
```

## License

See [LICENSE](/home/mike/opal/LICENSE).
