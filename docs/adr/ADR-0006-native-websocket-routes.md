# ADR-0006: Native WebSocket Routes

- Status: Accepted
- Date: 2026-08-05
- Deciders: Opal maintainers
- Extends: ADR-0003 and ADR-0004
- Related: `LF::HTTP::Router`, `LF::HTTP::Controller`, `LF::HTTP::AutoConfig`

## Context

Opal needs native WebSocket support as an HTTP route type. This is a lower
layer than Phoenix LiveView: it must expose Crystal's WebSocket API without
introducing a second web framework, a reactive runtime, or a custom socket
abstraction. The initial target is Crystal 1.21, whose WebSocket API supports
callbacks and synchronous receive methods, and whose
`HTTP::WebSocketHandler` owns the `ws.run` loop.

WebSocket connections also outlive the HTTP request that initiated their
upgrade. They therefore require an explicit DI lifetime and shutdown policy.

## Decision

### Routes and controller actions

`LF::HTTP::Router` gains a first-class `ws` route:

```crystal
router.ws("/chat/:id", protocols: ["chat.v1"]) do |ws, params|
  ws.on_message { |message| ws.send("echo: #{message}") }
end
```

The handler receives the unwrapped `HTTP::WebSocket` and route parameters. It
registers callbacks and returns `Nil`; `HTTP::WebSocketHandler` invokes
`ws.run`. Opal adds no wrapper, receive loop, callback DSL, or outbound-write
serialization policy over the Crystal standard library.

The same route may use Crystal's synchronous API instead: the action can call
`ws.receive` or `ws.receive?`, process messages, and close after its own loop.
A finite action must call `ws.close`; returning alone hands control back to
Crystal's handler, which then starts `ws.run`. This is not a second route type.
Applications should avoid mixing a manual receive loop with receive callbacks
on the same socket unless double processing is intentional; callback-mode
routes leave the loop to Crystal's handler.

Controllers use the same compile-time discovery path as HTTP controllers:

```crystal
@[LF::HTTP::Controller::WebSocket("/chat/:id", protocols: ["chat.v1"])]
def chat(ws : HTTP::WebSocket, id : Int64, request : HTTP::Request) : Nil
  ws.on_message { |message| ws.send("#{id}: #{message}") }
end
```

The action name is arbitrary. Valid arguments are the raw socket, supported
scalar route/query parameters, and an optional `HTTP::Request`; dependencies
remain constructor-injected. A WebSocket action must return `Nil`.

An HTTP route and a WebSocket route may not share a path. A non-upgrade request
to a known WebSocket path returns `426 Upgrade Required` and includes
`Upgrade: websocket`. Optional `protocols : Array(String)` is passed to
Crystal's subprotocol negotiation.

### Lifecycle, errors, and shutdown

After a successful upgrade, Opal opens one child DI scope named `"websocket"`.
WebSocket controller actions use a distinct `"websocket"` bean registration,
so a controller class may safely contain both HTTP and WebSocket actions. The
connection scope and everything it owns exit on disconnect, connection setup
failure, or server shutdown.

The standalone HTTP integration places `LF::HTTP::DI::WebSocketScopeHandler`
before `RequestScopeHandler`. Autoconfiguration places it inside the
connection-drain handler, which owns the ordinary request scope. After the
router installs Crystal's
`HTTP::Server::Response#upgrade_handler`, it wraps that handler. The wrapper
creates the connection scope only after a successful upgrade, stores it on the
HTTP context, and keeps it alive around the stdlib handler's full `ws.run`
execution. The ordinary request scope has already exited by then, so an
upgraded connection does not create a second request scope. The wrapper
restores the context and exits only the scope it owns.

Opal tracks active WebSocket connections. During application shutdown it stops
accepting new connections, sends each active connection close code `1001 Going
Away`, waits up to `http.websocket.shutdown_timeout_ms`, and force-closes any
remaining connections. The setting is an `Int32` in milliseconds and defaults
to `5000`. Force-close closes the upgrade IO; Crystal does not provide safe
forced cancellation for arbitrary user callback code, so callback bodies must
return for their DI scope to finish cleanup.

An exception during controller construction or action setup is logged through
`Log.error` with the exception and route path only, then closes the connection
with `1011 Internal Error`. Exceptions from callbacks registered directly on
the raw Crystal `HTTP::WebSocket` follow Crystal's native handler behavior;
Opal does not wrap the socket or serialize application writes. The close reason
does not expose the exception message to the peer. Opal never attempts to write
an HTTP error response after upgrade.

Origin policy that must reject a handshake can run in ordinary HTTP middleware
before the router. Application-, controller-, and action-level
`LF::HTTP::UseGuards` annotations also execute before upgrade and can return
`403 Forbidden`. The optional `HTTP::Request` in a WebSocket action is for
connection logic after upgrade, not handshake rejection.

## Compatibility and non-goals

This feature is additive: existing HTTP routes, request scopes, controller
semantics, and standalone server assembly remain unchanged.

This native route layer does not implement channels, DOM rendering, reconnect
state, presence, heartbeat policy, or a replacement for Crystal's callback
API. ADR-0007 defines Opal LiveView as an independent layer above it. Opal
LiveView deliberately does not implement the Phoenix wire protocol or depend
on Phoenix's JavaScript client.

## Consequences

- WebSocket applications use Crystal's documented text, binary, ping, pong,
  and close callbacks directly.
- Security policy stays application-owned and can run before HTTP upgrade.
- Long-lived controllers and disposable dependencies have connection lifetime,
  rather than accidentally retaining request-scoped metadata.
- Crystal 1.21 provides both callback and synchronous receive APIs. Opal's
  first route layer exposes the native socket directly, so applications may
  choose either style while the stdlib handler remains responsible for
  `ws.run` in callback-based handlers.

## Verification plan

Tests must cover route conflict rejection, `426` behavior, successful upgrade,
text/binary callback delivery, subprotocol negotiation, controller discovery
and argument binding, connection-scope disposal, `1011` error handling and
safe logging, and graceful shutdown including timeout fallback. Existing HTTP
and autoconfiguration specs remain part of the compatibility suite.
