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
   Compile-time route definition with request binding and constructor DI.

4. `@[LF::Application]` and `LF::ApplicationRuntime`
   Optional compile-time application assembly and root-container ownership.

5. `require "opal/autoconfig/http"`
   Optional HTTP controller discovery, server assembly, and lifecycle integration.

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
- JSON body parsing for `JSON::Serializable`
- automatic JSON responses for returned `JSON::Serializable` models
- `LF::HTTP::Response` return types such as `LF::HTTP::JSONResponse`
- constructor injection for controller dependencies

Route arguments are request inputs only. Inject services through the controller
constructor; unsupported route arguments fail at compile time.

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

@[LF::DI::Service]
class UserService
  def find(id : Int32) : UserView
    UserView.new(id, "User #{id}")
  end

  def create(name : String) : UserView
    UserView.new(1, name)
  end
end

class UsersApi
  include LF::HTTP::Controller

  def initialize(@users : UserService)
  end

  @[LF::HTTP::Controller::Get("/users/:id")]
  def show(id : Int32)
    @users.find(id)
  end

  @[LF::HTTP::Controller::Post("/users")]
  def create(payload : UserPayload)
    @users.create(payload.name)
  end
end

root = LF::DI::DefaultContainer.new
root.register(LF::DI::ServiceConfiguration.new)

app = LF::HTTP::App.new do |router|
  UsersApi.setup_routes(router, root)
end

server = HTTP::Server.new([
  LF::HTTP::DI::RequestScopeHandler.new(root),
  app,
])
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

Controllers are request-scoped beans. Their constructor dependencies use the
normal DI resolution rules. Route arguments bind only path, query, request, and
JSON body values.

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

The generated `bootstrap` method owns a fresh root container.
`LF::ApplicationRuntime` exposes typed resolution, extension installation,
shutdown, and state/error contracts; it does not expose the mutable root
container. Application extensions receive a controlled `LF::ApplicationContext`
for bean registration and scope creation.

## Data Transaction Rollback

`LF::Data::EntityManager` is transaction-local. If a transaction fails after an
explicit `flush`, generated IDs or optimistic-lock versions may already have
been written to in-memory entities even though the database rolled back.
Discard every entity obtained from the failed manager and do not reuse it:

```crystal
begin
  source.transaction do |manager|
    manager.persist(entity)
    manager.flush
    raise "abort"
  end
rescue
  # `entity` belongs to the failed manager and must be discarded.
end
```

## Configuration

Application bootstrap eagerly registers one immutable `LF::ConfigService`
singleton. It reads `config/application.yml` by default. A missing default file
means empty configuration; setting `OPAL_CONFIG` selects an explicit file and a
missing explicit file is an error.

```yaml
http:
  host: 127.0.0.1
  port: 8080
```

```crystal
config.get("http.port")       # YAML::Any
config.get("http.port", 8080) # Int32
config.section("http")        # YAML::Any mapping
```

## HTTP Autoconfiguration

HTTP autoconfiguration is an explicit optional require:

```crystal
require "opal"
require "opal/autoconfig/http"

@[LF::Application]
@[LF::AutoConfig::HTTP]
class TodoApplication
end

TodoApplication.run_http
```

At compile time Opal discovers `LF::HTTP::Controller` includers in
fully-qualified name order. At startup it builds the controller route table,
the standard log and request-scope handlers, and an `HTTP::Server`. The server
uses `http.host` (`0.0.0.0` by default) and `http.port` (`8080` by default).
`run_http` blocks in `HTTP::Server#listen`; process termination closes the
server before application DI shutdown.

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
  `LF::HTTP::Controller` with request-scoped DI and direct JSON model responses.

- [examples/di_lifecycle_example.cr](examples/di_lifecycle_example.cr)
  Standalone lifecycle example showing `after_properties_set`, `exit`, and `shutdown`.

- [examples/handler_stack_example.cr](examples/handler_stack_example.cr)
  Integration through a normal `HTTP::Handler` middleware stack.

- [examples/application_bootstrap_example.cr](examples/application_bootstrap_example.cr)
  Compile-time application discovery, generated entrypoints, and typed resolution.

- [examples/todo_api_sqlite](examples/todo_api_sqlite/README.md)
  Standalone Todo API project with SQLite persistence.

- [examples/data_layer_sqlite](examples/data_layer_sqlite/README.md)
  Standalone SQLite data-layer showcase covering mappings, queries, unit of
  work, migrations, optimistic locking, rollback behavior, manual HTTP, and
  Application + DI + controller-discovery HTTP.

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

For the standalone data-layer showcase, run commands from
`examples/data_layer_sqlite`:

```bash
shards install
crystal spec --no-color
crystal run src/data_layer_example_cli.cr
crystal run src/data_layer_example_http_cli.cr
crystal run src/data_layer_example_application_cli.cr
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

Controller methods may return a `JSON::Serializable` model directly; Opal writes it as
`application/json`. Explicit `LF::HTTP::Response` implementations remain available when
the response must control headers, status, or serialization behavior. Strings remain
plain text; collections are not auto-serialized.

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

### Application layer

- `LF::ConfigService::LoadError`
- `LF::ConfigService::MissingKeyError`
- `LF::ApplicationRuntime::ClosedError`
- `LF::ApplicationRuntime::ShutdownError`
- `LF::HTTP::AutoConfig::ConfigurationError`

## Testing

Run the full test suite:

```bash
crystal spec
```

## License

See [LICENSE](LICENSE).
