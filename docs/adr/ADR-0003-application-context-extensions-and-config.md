# ADR-0003: Application Context, Extensions, and ConfigService

- Status: Accepted
- Date: 2026-07-28
- Deciders: Opal maintainers
- Extends: ADR-0002
- Related: `LF::ApplicationRuntime`, `LF::DI::ScopeProvider`

## Context

ADR-0002 deliberately hid the mutable root DI container behind
`LF::ApplicationRuntime`. Integrations such as HTTP still need a controlled way
to register infrastructure beans, create child scopes, and stop their resources
before the root container is destroyed. Applications also need one conventional
configuration source that infrastructure extensions can inject.

These capabilities belong to the application layer. DI must not learn about
applications, HTTP servers, YAML paths, or extension ordering.

## Decision

### ApplicationContext

`LF::ApplicationContext` composes the application-owned
`LF::DI::DefaultContainer`; it does not inherit from it. It delegates:

- typed resolution;
- controlled bean registration for extensions;
- child scope creation through `LF::DI::ScopeProvider`.

`ApplicationRuntime` does not expose this context publicly. It passes the
context only to an extension during `install`.

### Application extensions

An extension implements:

```crystal
module LF::ApplicationExtension
  abstract def configure(context : LF::ApplicationContext) : Nil
  abstract def stop : Nil
end
```

`ApplicationRuntime#install` configures and records an extension. Shutdown
stops installed extensions in reverse installation order, then shuts down DI.
All extensions and DI receive a shutdown attempt even when an earlier stop
fails. Extension failures are reported as
`LF::ApplicationRuntime::ShutdownError`; a DI-only shutdown failure keeps its
original DI error type.

If extension configuration fails, the runtime calls `stop` on the partially
configured extension and closes the runtime. This destroys partial bean state
and stops previously installed extensions. An extension must therefore make
`stop` safe after partial configuration. When configuration and cleanup both
fail, `LF::ApplicationRuntime::InstallError` preserves both phases.

### Conditional application autoconfiguration

Optional packages can declare an application extension without adding a
package-specific branch to Application or DI:

```crystal
@[LF::ApplicationAutoConfiguration(
  enabled_by: LF::AutoConfig::Example,
  priority: 100
)]
class ExampleExtension
  include LF::ApplicationExtension

  def configure(context : LF::ApplicationContext) : Nil
  end

  def stop : Nil
  end
end
```

The descriptor is compile-time metadata. `enabled_by` names the marker
annotation that must also be present on the executable's one
`@[LF::Application]` class. Priority defaults to `0`; higher priority installs
first and equal priority is ordered by fully qualified extension name.

Application validates every descriptor visible in the executable: the marker
attribute is mandatory and resolves to an annotation type, priority is an
integer literal when explicitly present, the extension is
concrete, it includes `ApplicationExtension`, and its effective constructor can
be called without arguments. Constructor validation follows inherited
initializers and permits default arguments and untyped splats that accept an
empty call. A typed positional splat requires at least one value and is rejected.
An optional package that is not required contributes no descriptor and incurs
no validation or generated code.

Selection and ordering happen in `macro finished`. Bootstrap contains direct
`Extension.new` and `runtime.install` calls only for descriptors whose marker is
present; there is no runtime extension registry or class scan. Configuration
providers are registered before extensions are installed. Shutdown remains
reverse installation order.

If construction of a later extension fails, bootstrap shuts down the open
runtime so already installed extensions stop before DI. If
`ApplicationRuntime#install` already closed the runtime after a configure
failure, bootstrap does not shut down DI a second time. The original construction
or configure error is re-raised when cleanup succeeds; cleanup failure is
reported through `ApplicationRuntime::InstallError`.

HTTP autoconfiguration is intentionally not migrated to this generic descriptor
contract. It owns the blocking `run_http` executable entrypoint and remains an
independent integration decision.

### ScopeProvider

DI exposes only the narrow `LF::DI::ScopeProvider#enter_scope` contract.
`LF::DI::Container` implements it. Integrations depend on this contract instead
of requiring access to a mutable root container.

### ConfigService

Application bootstrap eagerly creates one singleton `LF::ConfigService`.

- `ENV["OPAL_CONFIG"]` selects an explicit YAML file.
- Otherwise `config/application.yml` is used.
- A missing default file produces empty configuration.
- A missing explicit file or malformed YAML raises
  `LF::ConfigService::LoadError`.
- Values are loaded once and are not reloaded.
- Dotted paths traverse YAML mappings.

The API is:

```crystal
config.get("http.port")
config.get("http.port", 8080)
config.section("http")
```

No environment-to-property overlay, profile system, schema binding, or runtime
reload is included.

## Consequences

- Application integrations can participate in startup and shutdown without
  exposing the root container.
- Optional integrations are selected and ordered entirely at compile time.
- An absent application marker produces no constructor or install call.
- The DI package remains independent of application and HTTP concerns.
- Configuration parsing happens once during bootstrap, not per request.
- Extension bean registration remains subject to existing DI duplicate and
  scope rules; this ADR adds no override semantics.
