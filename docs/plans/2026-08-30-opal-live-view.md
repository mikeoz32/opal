# Opal LiveView Implementation Plan

**Goal:** Deliver an Opal-owned server-rendered interactive page runtime above
native WebSocket routes, with no Phoenix server or JavaScript dependency.

**Architecture:** HTTP performs the disconnected render and signs immutable
mount metadata. The native WebSocket layer owns a connection DI scope. A small
JSON protocol mounts a fresh server view, serializes events per connection,
rerenders versioned HTML, answers heartbeats, and remounts after browser
reconnect. Opal serves a dependency-free ES module as the default client.

## Completed slices

1. Rebase native WebSocket routes onto current HTTP drain ownership.
2. Release request scope before upgrade and make late registration shutdown-safe.
3. Add signed mount tokens, same-origin handshake policy, limits, and safe errors.
4. Add disconnected/connected mount, events, render versions, and heartbeat.
5. Add click, change, submit, focus restoration, and reconnect browser runtime.
6. Add Application autoconfiguration and request/WebSocket constructor DI.
7. Add loopback protocol specs, a runnable counter example, and browser E2E.
8. Add event references and client-side queuing so rapid events are not lost.
9. Serialize timer/subscription updates through `send_info` and add join/idle timeouts.
10. Apply application/view guards to disconnected and connected mounts.
11. Add protocol-v2 structural snapshots and dynamic-position diffs while
    retaining protocol-v1 and `String`-render compatibility.
12. Morph compatible and keyed DOM nodes while preserving focused form state.
13. Add connection-local stateful components and explicitly targeted events.
14. Add protocol-v2 insert, update, delete, reset, position, and limit stream
    operations with browser-owned DOM collections.
15. Add `handle_params`, guarded same-view patching, refreshed mount tokens,
    push/replace history, popstate, and fresh-document navigation.
16. Add opt-in JavaScript hooks, DOM and reconnect lifecycle callbacks,
    targeted client events with replies, and server-pushed application events.
17. Add parent-scoped nested stateful components, bounded render trees, deep
    event targeting, and recursive child-first cleanup.

## Deferred protocol work

- upload transport and progress;
- same-socket navigation across an explicit live-session boundary;
- persisted reconnect/resume sessions where applications need them.

Each deferred feature requires an explicit protocol version or additive message
contract plus security and reconnect tests. Phoenix wire compatibility remains
out of scope.
