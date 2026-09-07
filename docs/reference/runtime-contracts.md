# Runtime contracts

This reference collects the lifecycle and failure boundaries most likely to
matter in a production integration.

## HTTP routing

| Condition | Result |
| --- | --- |
| no matching path | `404 Not Found` |
| matching path, unsupported HTTP method | `405 Method Not Allowed` and `Allow` header |
| HTTP request sent to a WebSocket route | `426 Upgrade Required` and `Upgrade: websocket` |
| duplicate normalized HTTP/WebSocket path | route registration error |

`LF::HTTP::App` converts Opal HTTP errors into status responses. A custom error
mapper can choose the response body format for a low-level router.

## Dependency injection

The root container owns singleton instances. Request and WebSocket handlers
own their child scopes. A child scope closes and destroys owned
`LF::DI::Disposable` values exactly once when its request or connection ends.
Resolving a shorter-lived bean from a singleton raises a scope mismatch instead
of leaking it into a longer lifecycle.

## Data

`DataSource#transaction` owns an `EntityManager` for its block. A manager must
not escape that block. Flush semantics, identity mapping, optimistic locking,
and relationship cascade order are documented in the Data pages.

Migrations are forward-only and record exact version/name history. PostgreSQL
acquires a session advisory lock; SQLite uses transactional history conflict
reconciliation. A dialect that cannot safely serialize migration execution
fails before history SQL begins.

## Security

An `Authenticator` returns `nil` only when its credential is absent. It raises
`InvalidCredentials` when a credential for its scheme is malformed or fails
verification; an authenticator chain therefore cannot accidentally fall through
to anonymous access after a bad API key or token.

`AuthenticatedGuard` and `AuthorityGuard` run through the ordinary controller
policy pipeline. CSRF protection applies to state-changing requests that used
a signed session; bearer and API-key requests do not carry a session CSRF
token.

## LiveView

`mount` runs for the initial disconnected render and again after connecting.
The signed mount token validates route identity but never grants resource
access; guards and page code must authorize the currently authenticated user on
both lifecycle paths. View state is per socket, and server-initiated work sends
messages to the connection fiber rather than mutating it from a background
fiber.
