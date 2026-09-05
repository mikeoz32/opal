# Application and configuration

Use the application layer when a program has more than one assembly concern:
HTTP server ownership, DataSource lifecycle, configuration, or custom runtime
extensions. It remains opt-in; a small router can be assembled manually.

## Mark the application

```crystal
require "opal"
require "opal/autoconfig/http"

@[LF::Application]
@[LF::AutoConfig::HTTP]
class MyApplication
end

MyApplication.run_http
```

At compile time, Opal discovers the selected configurations and generates the
assembly needed by `MyApplication`. At runtime, `ApplicationRuntime` owns the
root `DefaultContainer` and installed extensions.

## Configure by file and environment

`LF::ConfigService` loads the application configuration used by extensions.
HTTP autoconfiguration reads `http.host`, `http.port`, and `live_view.secret`
when LiveView is enabled. Data autoconfiguration accepts a selected datasource,
dialect, migrations, and migration options.

Keep secrets outside committed YAML. Pass them through the deployment
environment or a secret provider and compose the final application
configuration during deployment.

## Lifecycle rules

- Register long-lived application dependencies in the root container.
- Use request and WebSocket handlers to open scopes; they close them even when
  action code raises.
- An extension configures before it is recorded as active and stops in reverse
  installation order.
- A retryable extension shutdown retains the root DI container until it can
  release its resources safely.

The [application bootstrap ADR](../adr/ADR-0002-application-bootstrap-layer.md)
defines error and shutdown semantics in detail.

## When manual assembly is better

Use `LF::HTTP::App`, `LF::HTTP::Router`, and a `DefaultContainer` directly for
a small service, test harness, or embedded server. There is no penalty or
hidden requirement to use application annotations. Move to autoconfiguration
when the explicit assembly begins repeating application-wide concerns.
