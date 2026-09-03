# ADR-0007: Opal LiveView

- Status: Superseded by ADR-0009
- Date: 2026-08-30
- Deciders: Opal maintainers
- Extends: ADR-0004 and ADR-0006
- Related: `LF::LiveView`, `LF::HTTP::AutoConfig`

## Context

Opal applications need server-owned interactive pages without embedding the
Phoenix framework, implementing the Phoenix Channels protocol, or shipping the
Phoenix LiveView JavaScript package. Native WebSocket routes from ADR-0006 give
Opal the transport and connection lifecycle, but not page mounting, state,
events, rendering, reconnect, or a browser runtime.

Phoenix LiveView is useful prior art: its public lifecycle performs an initial
HTTP render followed by a stateful WebSocket mount, rerenders after events, and
remounts on reconnect. Its security guidance also treats URL parameters as
untrusted and requires authorization on both disconnected and connected mounts.
Opal adopts those general properties, not Phoenix's protocol or implementation.

## Decision

### Independent protocol and client

Opal owns a small JSON protocol under `LF::LiveView::Endpoint`. The browser
client is a dependency-free ES module embedded in the shard and served from
`/_opal/live.js`. Applications do not install `phoenix`, `phoenix_live_view`,
Node.js, or an asset bundler to use the default runtime.

The socket endpoint defaults to `/_opal/live`. Client messages are `join`,
`event`, `patch`, and `heartbeat`; server messages are `render`, `heartbeat`,
and non-fatal `error`. Events and patches carry the last applied render version
and a monotonically increasing connection-local `ref`. A stale operation is
not executed: the server sends its current render so the client can
resynchronize and retry it. The browser keeps one operation in flight and
queues later operations until the reference is acknowledged, preventing rapid
interactions from being silently dropped. The built-in client negotiates
protocol version `2`; the server still accepts version `1` for pages that do
not use v2-only streams or navigation. An unsupported version closes the
connection instead of silently changing semantics.

### View lifecycle and state

A page subclasses `LF::LiveView::View` and declares exactly one
`@[LF::LiveView::Page(path)]` annotation. Autoconfiguration creates separate
request-scoped and WebSocket-scoped instances and constructor-injects their
dependencies.

`mount(context)` runs twice:

1. with `connected? == false` for the initial HTTP render;
2. with `connected? == true` after the signed mount token is accepted.

`handle_params(context)` runs after each mount and again for an acknowledged
patch inside the same page route. Patch guards receive a synthetic GET request
for the target resource while retaining the active connection context.

The connected instance owns mutable page state and processes events serially
on the connection fiber. `render` returns either a structured `Rendered` value
or a compatibility `String`. `LF::LiveView::HTML.rendered` splits a literal
template into stable static fragments and automatically escaped dynamic
positions. `HTML.raw` is required for explicitly trusted dynamic markup.
`handle_event` mutates server state and the endpoint rerenders afterward.
State changes originating from a subscription, timer, or other application
fiber call protected `send_info`. `handle_info` executes the mutation on the
connection fiber; events, info messages, renders, and outbound writes therefore
remain serialized. `refresh` is reserved for coalescing a render requested by
code already executing on the connection fiber.

Each view composes one `LF::LiveView::ConnectionRuntime`. The runtime, rather
than the application view, owns connection infrastructure: the component tree,
stream operations, pending navigation, pushed browser events, event replies,
and `send_info`/refresh dispatchers. These concerns are isolated into runtime
subsystems and are cleared together at disconnect. `View` remains the
application callback and protected helper facade.

`ConnectionRuntime` is deliberately not an `ApplicationExtension`.
Application extensions have application lifetime and may be shared by every
request and socket, while this state belongs to exactly one disconnected render
or WebSocket connection. The HTTP extension owns route and endpoint startup;
the per-view runtime is the composition boundary for later connection-scoped
features such as uploads and live sessions.

On transport reconnect, the server creates a new WebSocket scope and mounts a
new view from the latest signed path, route params, query params, and the new
handshake request. Successful patches refresh that signed state. Ephemeral
non-URL state still resets unless the application persisted it. Opal does not
serialize arbitrary server state into the browser.

### Rendering and browser bindings

Protocol v2 sends the template fingerprint, static fragments, and dynamic
values for its first connected render. If the next render has the same
fingerprint, the server sends a map containing only changed dynamic positions.
A changed template sends a new complete snapshot. A view returning `String` is
treated as opaque and therefore needs a complete snapshot whenever its HTML
changes. Protocol v1 continues returning complete `html` payloads.

The browser reconstructs trusted server HTML and morphs the existing DOM.
Compatible unkeyed elements retain identity by position; `id` and
`data-opal-key` provide stable identity across insertion and reordering.
Focused form controls retain their browser-owned value and selection. The
client updates the document title and emits `opal:render` after the patch.

The default client supports:

- `data-opal-click="event"`;
- `data-opal-change="event"`, with optional `data-opal-debounce="milliseconds"`;
- `data-opal-submit="event"` on forms;
- `data-opal-value-*` values on event targets;
- `data-opal-target="component-id"` for stateful component events;
- `data-opal-patch` and optional `data-opal-replace` for same-view history;
- `data-opal-navigate` for a fresh document mount;
- `data-opal-hook` for application-owned JavaScript lifecycle integration;
- automatic heartbeat and bounded exponential reconnect;
- `opal:render`, `opal:error`, `opal:event-error`, and `opal:hook-error`
  browser events.

The form encoder preserves repeated names as arrays. Connection-local stateful
components use parent-scoped `(component type, id)` identity, mount once,
update before each render, can recursively render bounded stateful child trees,
and receive explicitly targeted events on the same connection fiber. Removed
component trees are destroyed child-first. Components can request navigation
through their parent connection. Views and components can reply to the current
event and enqueue application events for browser hooks. File uploads and
same-socket navigation across page classes are deferred.

Hook definitions are application-owned and registered before the embedded
module loads. Hook elements require a unique stable DOM id. The client creates
one isolated hook instance per element and invokes `mounted`, synchronous
`beforeUpdate`, `updated`, `destroyed`, `disconnected`, and `reconnected`
callbacks around normal morph, stream, and transport lifecycle transitions.
Hook errors emit a local diagnostic event without failing the server-owned
connection. `pushEvent` and `pushEventTo` share the versioned, one-operation-
in-flight queue; acknowledgements may carry one JSON reply. Server-pushed
events are delivered after the DOM patch to registered hook handlers and as
namespaced window events. Custom events and replies are additive protocol-v2
fields and are rejected for protocol-v1 clients rather than silently lost.

Live patches are additive protocol-v2 messages. The server validates an
absolute local resource against the current page route, reruns guards, invokes
`handle_params`, and returns the normalized target plus a refreshed signed
mount token. The client updates history only after that response. Popstate
patches use the same event queue and do not create another entry. Navigation
across page classes uses a fresh HTTP document until Opal defines an explicit
live-session authorization boundary.

Protocol-v2 stream operations address a marked container and carry ordered
insert, delete, or reset mutations. The browser validates that inserts contain
one root element with the declared DOM id, morphs updates in place, and applies
optional position and size limits. Normal structural rendering preserves
children of `data-opal-stream` containers so the connected view does not need
to retain the collection. Protocol-v1 connections are rejected when a view
queues streams rather than receiving an incomplete representation. These
remaining boundaries are Opal protocol choices, not Phoenix compatibility.

### Security

`live_view.secret` is mandatory when an annotated page exists and must contain
at least 32 bytes. The initial response includes an HMAC-SHA256 mount token over
the route identity, route params, original resource, and issuance time. Tokens
expire after `live_view.mount_token_max_age_ms`, which defaults to 24 hours.

The default socket handshake requires an `Origin` header matching `Host` and
rejects mismatches before the WebSocket upgrade. Deployments behind unusual
proxies can set an explicit `live_view.allowed_origins` allowlist. This check is
not a replacement for application authentication or authorization.

Both disconnected and connected `mount` calls receive an `HTTP::Request`.
Application-level and view-level `LF::HTTP::UseGuards` annotations execute for
both mounts. Views must still authorize resource-specific events because
parameters, event payloads, and client state are not authority. Tokens protect
integrity, not confidentiality, and are escaped before insertion into HTML.
Protocol and user-code failures use safe close reasons. Opal does not add tokens
or event values to log metadata; application exception messages remain
application-owned and must not embed secrets.

### Shutdown and limits

LiveView connections use the normal `"websocket"` DI scope and WebSocket
registry. Application shutdown stops new registrations, sends `1001 Going
Away`, force-closes transports after the configured WebSocket timeout, and
waits for the connection scope under the overall HTTP drain deadline.

Inbound text messages are limited by `live_view.max_message_bytes` (64 KiB by
default). Binary protocol messages are rejected. A client must join within
`live_view.join_timeout_ms` (10 seconds by default) and send traffic within
`live_view.idle_timeout_ms` (75 seconds by default). Heartbeats keep idle
browser connections observable; application events remain ordered per
connection.

## Consequences

- Interactive Opal pages require no Phoenix or npm dependency.
- The server remains the source of truth and owns one view instance per live
  connection.
- The protocol is intentionally smaller than Phoenix LiveView and can evolve
  under Opal's own compatibility rules.
- Protocol v2 reduces steady-state payloads and DOM churn for structured
  renders, while protocol v1 and opaque `String` renders retain a simpler
  compatibility path.
- Opt-in hooks cover application JavaScript interoperability without adding a
  framework or bundler dependency to the default client.
- Parent-scoped component identities allow reusable nested component trees
  without collisions between separate parent instances. Recursive identities
  and excessive nesting fail the render instead of growing without bound.
- A dedicated connection runtime keeps transport-adjacent queues and component
  registries out of application views without sharing mutable session state
  through an application-wide extension.

## References

- [Phoenix LiveView lifecycle](https://github.com/phoenixframework/phoenix_live_view/blob/main/lib/phoenix_live_view.ex)
- [Phoenix LiveView bindings](https://phoenix-live-view.hexdocs.pm/bindings.html)
- [Phoenix stateful components](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveComponent.html)
- [Phoenix LiveView streams](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html#module-streams)
- [Phoenix JavaScript interoperability](https://phoenix-live-view.hexdocs.pm/js-interop.html)
- [Phoenix LiveView security model](https://phoenix-live-view.hexdocs.pm/security-model.html)
