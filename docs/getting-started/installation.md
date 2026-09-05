# Install Opal

## Prerequisites

Opal supports Crystal 1.21 and newer. Start in an application directory with a
`shard.yml`:

```yaml
dependencies:
  opal:
    github: mikeoz32/opal
```

Install dependencies:

```bash
shards install
```

The core import is deliberately small:

```crystal
require "opal"
```

It gives you the router, HTTP app, controller macros, DI, application runtime,
native WebSocket support, and LiveView server integration. Add optional imports
only when the application uses those layers:

| Capability | Import | Extra application dependency |
| --- | --- | --- |
| SQLite Data | `opal/data`, `opal/data/dialects/sqlite` | `crystal-sqlite3` |
| PostgreSQL Data | `opal/data`, `opal/data/dialects/postgresql` | `crystal-pg` |
| Application-owned DataSource | `opal/autoconfig/data` | selected driver and dialect |
| HTTP assembly from application annotations | `opal/autoconfig/http` | none |
| UI components | `opal/ui` | none |
| API key and signed-session security | `opal/security` | none |
| JWT and OIDC resource tokens | `opal/security/jwt` | `crystal-community/jwt` |

## Verify the installation

Create `src/app.cr`:

```crystal
require "opal"

router = LF::HTTP::Router.new
router.get("/") { |context, _params| context.response.print "Opal is running" }

server = HTTP::Server.new(router)
server.bind_tcp(8080)
server.listen
```

Then run it:

```bash
crystal run src/app.cr
curl http://127.0.0.1:8080/
```

Continue with [Your first HTTP API](../tutorials/first-api.md) for the
controller and DI style used by larger applications.
