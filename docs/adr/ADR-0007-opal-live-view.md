# ADR-0007: Opal LiveView

- Status: Accepted
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
`event`, and `heartbeat`; server messages are `render`, `heartbeat`, and
non-fatal `error`. Event messages carry the last applied render version. A
stale event is not executed: the server sends its current render so the client
can resynchronize and retry it. Every event also carries a monotonically
increasing connection-local `ref`; its render or error response echoes that
reference. The browser keeps one event in flight and queues later events until
the reference is acknowledged, preventing rapid interactions from being
silently dropped. Join and render messages carry protocol version `1`; an
unsupported version closes the connection instead of silently changing
semantics.

### View lifecycle and state

A page subclasses `LF::LiveView::View` and declares exactly one
`@[LF::LiveView::Page(path)]` annotation. Autoconfiguration creates separate
request-scoped and WebSocket-scoped instances and constructor-injects their
dependencies.

`mount(context)` runs twice:

1. with `connected? == false` for the initial HTTP render;
2. with `connected? == true` after the signed mount token is accepted.

The connected instance owns mutable page state and processes events serially
on the connection fiber. `render` returns trusted HTML for the root's contents;
application values interpolated into it must use `LF::LiveView::HTML.escape`.
`handle_event` mutates server state and the endpoint rerenders afterward.
State changes originating from a subscription, timer, or other application
fiber call protected `send_info`. `handle_info` executes the mutation on the
connection fiber; events, info messages, renders, and outbound writes therefore
remain serialized. `refresh` is reserved for coalescing a render requested by
code already executing on the connection fiber.

On transport reconnect, the server creates a new WebSocket scope and mounts a
new view from the original signed path, route params, query params, and the new
handshake request. Ephemeral socket state therefore resets unless the
application persisted it. Opal does not serialize arbitrary server state into
the browser.

### Rendering and browser bindings

The v1 protocol sends complete root HTML, not a Phoenix-compatible structural
diff. The client replaces the root contents, restores focus and text selection
when possible, updates the document title, and emits `opal:render`.

The default client supports:

- `data-opal-click="event"`;
- `data-opal-change="event"`, with optional `data-opal-debounce="milliseconds"`;
- `data-opal-submit="event"` on forms;
- `data-opal-value-*` values on event targets;
- automatic heartbeat and bounded exponential reconnect;
- `opal:render`, `opal:error`, and `opal:event-error` browser events.

The form encoder preserves repeated names as arrays. File uploads, client
hooks, nested stateful components, live navigation, and minimal DOM diffs are
deferred. Their absence is an explicit v1 boundary, not Phoenix compatibility.

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
- Full-root HTML is simple and deterministic but can transfer more data and do
  more DOM work than a structural diff. A future diff format must be negotiated
  as a protocol version rather than silently changing v1 semantics.

## References

- [Phoenix LiveView lifecycle](https://github.com/phoenixframework/phoenix_live_view/blob/main/lib/phoenix_live_view.ex)
- [Phoenix LiveView bindings](https://phoenix-live-view.hexdocs.pm/bindings.html)
- [Phoenix LiveView security model](https://phoenix-live-view.hexdocs.pm/security-model.html)
