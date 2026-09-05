# Module selection

Opal is split at its public `require` boundaries. Importing an entry point is a
compile-time declaration of which surface an application is willing to use.

| Import | Provides | Does not provide |
| --- | --- | --- |
| `opal` | router, app, controllers, DI, application runtime, WebSockets, LiveView server | database drivers, UI, authenticators |
| `opal/autoconfig/http` | application-driven controller and HTTP assembly | DataSource or database driver |
| `opal/data` | entity mapping, queries, repositories, migrations, transaction APIs | a concrete database dialect or driver |
| `opal/data/dialects/sqlite` | SQLite SQL, introspection, and DDL contracts | SQLite driver import |
| `opal/data/dialects/postgresql` | PostgreSQL SQL, advisory migration lock, introspection, and DDL contracts | PostgreSQL driver import |
| `opal/autoconfig/data` | application-owned DataSource and optional startup migrations | selected driver and dialect |
| `opal/ui` | stateless components, precompiled Tailwind theme, optional UI hooks | LiveView client initialization |
| `opal/security` | authentication context, API keys, signed sessions, guards, CSRF | JWT implementation |
| `opal/security/jwt` | JWT and OIDC resource-token authenticators | browser login redirect/callback flow |

## Import combinations

### Minimal JSON API

```crystal
require "opal"
```

Assemble `LF::HTTP::App`, a `DefaultContainer`, and request scope handlers
manually.

### Convention-based HTTP application

```crystal
require "opal"
require "opal/autoconfig/http"
```

Use `@[LF::Application]` and `@[LF::AutoConfig::HTTP]` to discover controllers
and own the server lifecycle.

### SQLite or PostgreSQL service

```crystal
require "opal"
require "opal/data"
require "opal/data/dialects/postgresql"
require "pg"
```

For application-owned datasource setup, add `opal/autoconfig/data`. The driver
still belongs to the consuming application.

### Secure LiveView application

```crystal
require "opal"
require "opal/autoconfig/http"
require "opal/security"
require "opal/ui"
```

LiveView uses the authenticated HTTP request and WebSocket handshake context.
For a browser application, use an opaque signed session cookie today; the JWT
and OIDC adapter is designed for bearer resource tokens, not a browser
authorization-code callback.
