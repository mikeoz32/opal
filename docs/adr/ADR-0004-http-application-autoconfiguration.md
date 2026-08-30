# ADR-0004: HTTP Application Autoconfiguration

- Status: Accepted
- Date: 2026-07-28
- Deciders: Opal maintainers
- Extends: ADR-0002 and ADR-0003
- Related: `LF::HTTP::Controller`, `LF::HTTP::DI::RequestScopeHandler`

## Context

Standalone Opal HTTP applications can assemble a router, request scope handler,
and `HTTP::Server` explicitly. Application-based executables need the same
parts assembled consistently without coupling core application bootstrap to
HTTP or introducing runtime controller discovery.

Controller service injection through route arguments also mixes request
binding with DI. A controller should be the request-scoped DI boundary, while
its methods should describe only HTTP inputs.

## Decision

### Explicit opt-in

HTTP integration is loaded only by:

```crystal
require "opal/autoconfig/http"
```

Requiring the file alone has no runtime behavior. An application opts in by
placing both annotations on the same class:

```crystal
@[LF::Application]
@[LF::AutoConfig::HTTP]
class TodoApplication
end
```

Using `@[LF::AutoConfig::HTTP]` without `@[LF::Application]` is a compile-time
error. The integration generates `TodoApplication.run_http : Nil`; the core
application package does not import or know about HTTP.

### Controller assembly

`LF::HTTP::Controller` provides a class macro:

```crystal
UsersApi.setup_routes(router, scope_provider)
```

At expansion time it registers the controller as a request-scoped bean and
generates route closures. `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, and
`OPTIONS` have explicit controller annotations. Constructor arguments use DI's
existing name-then-type `resolve_dependency` behavior. Each route resolves its
controller from the request child scope by a stable, fully-qualified internal
bean name, so request dispatch uses a hash lookup and does not scan by type.

Route method arguments are limited to:

- supported scalar path or query values;
- `HTTP::Request`;
- `JSON::Serializable` request bodies.

Any other route argument is a compile-time error instructing the author to use
constructor injection. The former runtime
`Controller.new.setup_routes(router)` API is removed before the first stable
release.

Standalone HTTP remains supported by passing `LF::DI::DefaultContainer`.
Application autoconfiguration passes `LF::ApplicationContext`.

### Discovery and server

The integration discovers `LF::HTTP::Controller.includers` at compile time and
orders them by fully-qualified class name. Startup builds one route table. A
connection-aware server dispatch wrapper owns transport registration and invokes
this handler chain:

1. `LF::HTTP::AutoConfig::ConnectionDrainHandler`
2. `HTTP::LogHandler`
3. `LF::HTTP::App`

The connection drain handler rejects new work during shutdown and tracks
response completion, idle keep-alive sockets, and upgraded connection work.
It also creates the real child `LF::DI::Container`, stores it on the HTTP
context, and exits it only after response output closes or upgraded work returns.
This gives request-scoped dependencies the same ownership boundary as the
transport work that may capture them. `RequestScopeHandler` remains available
for manually assembled standalone handler chains that do not use HTTP
autoconfiguration.

`http.host`, `http.port`, and `http.drain_timeout_ms` come from
`LF::ConfigService`, with defaults `0.0.0.0`, `8080`, and `30000`. Port `0` is
valid and the drain timeout must be positive. Invalid values raise
`LF::HTTP::AutoConfig::ConfigurationError`.

`run_http` blocks in `HTTP::Server#listen`. `Process.on_terminate` closes the
server. Extension stop is idempotent. It first rejects new requests and closes
the listening and idle sockets, then waits for active request scopes, response
output, and upgraded work to exit before application shutdown destroys root DI.
At the deadline it force-closes remaining transports and returns a typed
`LF::HTTP::AutoConfig::DrainTimeoutError`. That error marks application shutdown
as incomplete: new application resolution stays disabled, but root DI remains
alive while request scopes can still reference it. Once the remaining work has
exited, retrying shutdown completes extension stop and root DI disposal.

Router method dispatch is exact; `HEAD` and `OPTIONS` require explicit routes.
Method mismatch returns `405` with sorted `Allow` metadata. A caller may supply
`LF::HTTP::Router::ErrorMapper` to replace the default error body without
changing the status or `Allow` header.

## Performance

- Controller discovery and route generation occur at compile time.
- Configuration is read once during application bootstrap.
- The route table is built once during HTTP extension installation.
- Each request adds one child DI scope, one named controller lookup, and one
  request-scoped controller instance.
- There is no runtime reflection, controller scan, or per-request route setup.

## Consequences

- Small applications may keep explicit handler assembly; application
  executables may use one annotation and `run_http`.
- Controller constructors become the single service injection boundary.
- Existing request binding, response serialization, and HTTP error behavior are
  preserved.
- Route conflicts are deterministic because discovery order is deterministic.
