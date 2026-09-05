---
search:
  boost: 2
---

# Opal

Opal is a modular toolkit for building Crystal applications: explicit HTTP
routing, compile-time controllers and policies, scoped dependency injection,
transaction-local data access, native WebSockets, server-rendered LiveView,
optional UI primitives, and opt-in security.

The project favours contracts that are visible in the program. A Data
transaction is a block; a dependency scope has a deterministic owner; an
interactive page remains server-rendered; and authentication is resolved once
per request or WebSocket handshake.

<div class="grid cards" markdown>

-   :material-rocket-launch-outline: **Start an app**

    Build a small JSON API, then evolve it into a database-backed service.

    [First HTTP API](tutorials/first-api.md)

-   :material-database-outline: **Use the Data layer**

    Map entities at compile time and keep all reads and writes explicit.

    [Data overview](data/getting-started.md)

-   :material-lightning-bolt-outline: **Build interactive pages**

    Use upstream Phoenix LiveView browser behavior without adopting Phoenix.

    [LiveView guide](live-view.md)

-   :material-shield-lock-outline: **Protect an API**

    Compose authenticators, guards, CSRF checks, API keys, signed sessions,
    JWT, and OIDC resource-token validation.

    [Security guide](security.md)

</div>

## Choose only the layers you use

`require "opal"` loads routing, HTTP controllers, DI, application runtime and
LiveView. Data, UI, autoconfiguration, and security are separate entry points.
This keeps a small API-only service from inheriting a database driver, a UI
theme, or an authentication strategy it does not need.

```crystal
require "opal"                  # HTTP, DI, application runtime, LiveView
require "opal/data"             # explicit data API
require "opal/autoconfig/data"  # Application-owned DataSource
require "opal/ui"               # optional Tailwind UI primitives
require "opal/security"         # authentication and authorization
require "opal/security/jwt"     # JWT and OIDC resource-token adapters
```

See the complete [module selection reference](reference/modules.md) before
choosing an entry point.

## Learning path

1. [Install Opal](getting-started/installation.md) and run the smallest
   router.
2. Complete [Your first HTTP API](tutorials/first-api.md) to learn controller
   routes, request binding, and DI.
3. Complete the [Todo API tutorial](tutorials/todo-api.md) for entities,
   repositories, migrations, and explicit transactions.
4. Complete the [LiveView counter tutorial](tutorials/live-view-counter.md)
   for connected state, events, and `phx-*` bindings.
5. Add policies from the [HTTP controller guide](guides/http-controllers.md)
   and identity from the [Security guide](security.md).

## Principles and deliberate boundaries

Opal intentionally does **not** implement lazy relationships, proxy entities,
automatic dirty checking, schema auto-sync, migration rollback, automatic
retries, or a hidden second-level cache. The Data guide documents the full
boundary. LiveView uses the upstream Phoenix browser client but Opal owns the
Crystal server contract and does not require Elixir or Phoenix in application
projects.

For architectural rationale, see the [Architecture Decision Records](adr/README.md).
