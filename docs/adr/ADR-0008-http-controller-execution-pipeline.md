# ADR-0008: HTTP Controller Execution Pipeline

- Status: Accepted
- Date: 2026-08-30
- Deciders: Opal maintainers
- Extends: ADR-0004
- Related: `LF::HTTP::Controller`, `LF::DI`, `LF::HTTP::App`

## Context

Controller actions currently combine request binding and application behavior in
one generated route closure. Applications need reusable authorization,
validation/transformation, around-action behavior, and exception mapping without
duplicating those concerns in every controller. These extension points must keep
Opal's compile-time controller discovery and request-scoped DI ownership.

The design must not add runtime reflection, hidden service locators, or lazy
request behavior. A policy is a normal DI bean and receives the current request
through an explicit execution context.

## Decision

### Policy contracts

The HTTP package provides four policy contracts:

- `Guard#can_activate` authorizes an action. Returning `false` raises
  `LF::HTTP::Forbidden`; a guard may raise a more specific HTTP error.
- `Pipe#transform` validates or transforms a bound input before Crystal type
  conversion. `StringPipe` handles path/query strings and `JSONPipe` handles a
  parsed JSON body.
- `Interceptor#intercept` receives a `CallHandler`, may execute code before and
  after it, replace its `LF::HTTP::Response`, or short-circuit without calling it.
- `Filter#catch` maps an exception to an optional `LF::HTTP::Response`.
  `ExceptionFilter` plus `handles ErrorType` provides typed dispatch.

Every policy receives `LF::HTTP::ExecutionContext`, which exposes the standard
HTTP server context, request, response, route params, controller name, action
name, and current request DI scope.

Policies are resolved from that request scope. They must therefore be registered
as DI beans, either with `@[LF::DI::Service]`, a bean configuration, or explicit
container registration. Their configured DI scope controls their lifecycle.

### Binding annotations and order

`@[LF::HTTP::UseGuards(...)]`, `UsePipes`, `UseInterceptors`, and `UseFilters`
accept concrete policy types. The controller compiler validates the policy base
type at compile time.

For guards, pipes, and interceptors the resolution order is:

1. global owner;
2. controller class;
3. action method;
4. action parameter, for pipes only.

Interceptors enter in that order and unwind in reverse order. Filters use the
opposite scope precedence: action, controller, then global. The first filter
that returns a response handles the exception.

The complete request sequence is:

1. existing `HTTP::Handler` middleware;
2. guards;
3. interceptor `before` path;
4. pipes and request argument conversion;
5. request-scoped controller resolution and action invocation;
6. interceptor `after` path in reverse order;
7. response rendering.

Filters surround guard execution, interceptor execution, binding, controller
invocation, and response rendering. An unhandled `LF::HTTP::Error` retains its
status. Other unhandled exceptions retain the controller's existing 500 mapping.

### Input model

Pipes operate on transport values before conversion:

- path and query inputs are `String`;
- a JSON body is `JSON::Any` and is converted to the declared
  `JSON::Serializable` type after all pipes complete.

`ArgumentMetadata` identifies the parameter name, target type, and source.
`HTTP::Request` remains a raw framework input and cannot have pipes. One action
may declare at most one JSON body argument; this makes body ownership explicit
and removes the previous accidental second-read behavior.

### Global policies

For application autoconfiguration, the `@[LF::Application]` class is the global
annotation owner. Standalone assembly passes an explicit owner type as the third
argument to `Controller.setup_routes`:

```crystal
UsersController.setup_routes(router, root, HttpPolicies)
```

Omitting the third argument preserves standalone controller behavior with no
global policies.

## Consequences

- Cross-cutting HTTP behavior is reusable, ordered, DI-owned, and testable.
- Authorization can run before request parsing and controller construction.
- Interceptors can short-circuit or replace a normalized response without
  depending on controller return types.
- Filters see original application exceptions before generic 500 wrapping.
- Policy configuration is visible in annotations and compiled into each route;
  there is no per-request policy discovery.
- Routes without pipes retain direct scalar and JSON binding; they do not pay
  for an intermediate JSON parse/serialization pass.
- Pipe transformations deliberately stop at transport values. Domain conversion
  remains explicit in application code or the declared JSON model.
