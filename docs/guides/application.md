# Application and configuration

Use the application layer when a program has more than one assembly concern:
HTTP server ownership, DataSource lifecycle, configuration, or custom runtime
extensions. It remains opt-in; a small router can be assembled manually.

## Mark the application

```crystal
--8<-- "examples/documentation/application_guide.cr"
```

At compile time, Opal discovers the selected configurations and generates the
assembly needed by `MyApplication`. At runtime, `ApplicationRuntime` owns the
root `DefaultContainer` and installed extensions.

## Configure from YAML

`LF::ConfigService` loads the application configuration used by extensions.
HTTP autoconfiguration reads `http.host`, `http.port`, and `live_view.secret`
when LiveView is enabled. Data autoconfiguration accepts a selected datasource,
dialect, migrations, and migration options.

By default Opal reads `config/application.yml`. `OPAL_CONFIG` selects a
different YAML file; it does not overlay individual environment variables or
contact a secret provider. Keep secrets outside version control and have the
deployment system render or mount the final YAML before starting Opal.

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
