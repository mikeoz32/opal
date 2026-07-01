# ADR-0002: Application Bootstrap Layer

- Status: Proposed
- Date: 2026-07-02
- Deciders: Opal maintainers
- Related: `LF::DI` container, `LF::APIRoute` integration, future `LF::Data` layer

## Context

Opal currently has a DI core and HTTP API layer, but application startup is still assembled manually.
Applications create a root `LF::DI::AnnotationApplicationContext`, explicitly register DI configurations, wire HTTP handlers, and manually decide when to call `shutdown`.

That is acceptable for a small example, but it does not give future infrastructure layers a stable place to plug in. A database layer, configuration system, profiles, health checks, and other enterprise-style capabilities all need a shared bootstrap model.

At the same time, Opal should keep the simple path simple. The application layer should not turn the DI container into a magic runtime scanner, and runtime configuration values such as database URLs or credentials should not be embedded into compile-time annotations.

## Decision

We will introduce a thin application bootstrap layer above `LF::DI`.

The application layer is responsible for creating the root application context, registering standard framework configurations, discovering application configuration classes at compile time, and coordinating shutdown.

The DI container remains responsible for bean registration, lookup, scoping, lifecycle callbacks, and dependency resolution. It should not become responsible for discovering whole applications.

### 1) Compile-time discovery, runtime values

Compile-time mechanisms should describe the shape of the application:

- application entrypoint
- configuration classes
- service classes
- bean factory methods
- dependency graph shape where Crystal macros can observe it

Runtime configuration should provide environment-specific values:

- database URLs
- credentials
- pool sizes
- timeouts
- feature flags
- profile names

Annotations may identify application structure, but they should not carry environment-specific values.

### 2) Application entrypoint

Add an application marker annotation for the top-level application type.

```crystal
@[LF::Application]
class TodoApp
end
```

The exact runtime API can evolve, but the expected shape is:

```crystal
app = LF::Application.run(TodoApp)
```

or:

```crystal
context = LF::Application.bootstrap(TodoApp)
```

The bootstrap result should expose the root context and provide an explicit shutdown path.

### 3) Configuration discovery

Add a configuration marker for classes that participate in application bootstrap.

```crystal
@[LF::DI::Configuration]
class AppConfig
  include LF::DI::ApplicationConfig

  @[LF::DI::Bean]
  def database_config : LF::Data::DatabaseConfig
    LF::Data::DatabaseConfig.from_env("APP_DB")
  end
end
```

In v1, configuration classes should still use `include LF::DI::ApplicationConfig` to get the existing compile-time bean factory behavior. The annotation makes the class discoverable by the application bootstrap layer.

### 4) Standard bootstrap behavior

Application bootstrap v1 should:

1. Create the root `LF::DI::AnnotationApplicationContext`.
2. Register `LF::DI::AutowiredApplicationConfig`.
3. Register all discovered `@[LF::DI::Configuration]` classes.
4. Return an application/context object that can be shut down explicitly.
5. Ensure shutdown delegates to the root context.

## Not In Scope For v1

- database layer
- web server auto-start
- property binding
- profiles
- conditional beans
- module system
- classpath-style runtime scanning
- automatic external dependency installation
- repository abstraction
- ORM
- health checks and metrics

These capabilities should build on the application layer after the bootstrap contract is stable.

## Detailed Requirements

1. Application bootstrap must be explicit from user code.
2. Configuration discovery must happen at compile time.
3. Runtime values must come from runtime sources, not application annotations.
4. Existing explicit DI registration must keep working.
5. The application layer must not remove the ability to use `LF::Router`, `LF::LFApi`, or `LF::DI` independently.
6. Shutdown must be explicit and deterministic.
7. The implementation must be small enough to support the future data layer without pulling database concerns into bootstrap.

## Proposed API Shape (v1)

### Annotations

- `@[LF::Application]`
- `@[LF::DI::Configuration]`

### Runtime types

- `LF::ApplicationContext` or `LF::ApplicationInstance`
- `LF::Application.run(AppType)`
- `LF::Application.bootstrap(AppType)`

The final names should be validated during implementation. The important contract is that the application layer owns bootstrap orchestration and exposes the root DI context.

### Configuration classes

Configuration classes remain ordinary Crystal classes:

```crystal
@[LF::DI::Configuration]
class DataConfig
  include LF::DI::ApplicationConfig

  @[LF::DI::Bean]
  def database_config : LF::Data::DatabaseConfig
    LF::Data::DatabaseConfig.from_env("APP_DB")
  end
end
```

This preserves the existing `@[LF::DI::Bean]` model and avoids adding database-specific annotations before the data layer is designed.

## Consequences

### Positive

- Gives future infrastructure layers a stable bootstrap foundation.
- Keeps DI core focused on dependency resolution instead of application discovery.
- Makes configuration registration less manual without requiring runtime scanning.
- Preserves a simple path for small applications.
- Creates a natural place for future auto-configuration, profiles, and data infrastructure.

### Trade-offs

- Introduces a new top-level concept in Opal.
- Requires clear documentation so users understand the difference between DI core and application bootstrap.
- Compile-time discovery can surprise users if the inclusion rules are too broad.
- Future features must avoid pushing runtime values into annotations.

## Implementation Plan (High-Level)

1. Add `@[LF::Application]` marker annotation.
2. Add `@[LF::DI::Configuration]` marker annotation.
3. Add a small application bootstrap type/module.
4. Generate a compile-time bootstrap plan for discovered configuration classes.
5. Register `LF::DI::AutowiredApplicationConfig` by default.
6. Register discovered configuration instances in deterministic order.
7. Return an application/context object with access to the root DI context.
8. Add explicit shutdown support.
9. Update examples to show both explicit DI and application bootstrap styles.

## Testing Strategy

- Unit tests for configuration discovery.
- Tests that `@[LF::DI::Configuration]` classes are registered automatically during application bootstrap.
- Tests that explicit DI registration still works without the application layer.
- Tests that `LF::DI::AutowiredApplicationConfig` is registered by default.
- Tests that shutdown delegates to the root context.
- Regression tests for duplicate beans and ambiguous bean behavior during bootstrap.

## Future Work

- `LF::Data` database infrastructure built as explicit auto-configuration.
- Profiles and conditional beans.
- Property binding from environment/config files.
- Module imports.
- Web application bootstrap that can assemble an `HTTP::Server`.
- Health checks, metrics, and observability hooks.
