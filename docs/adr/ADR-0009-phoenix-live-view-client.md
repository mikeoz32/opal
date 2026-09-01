# ADR-0009: Phoenix LiveView Browser Runtime Compatibility

- Status: Accepted
- Date: 2026-09-01
- Deciders: Opal maintainers
- Supersedes: ADR-0007's independent protocol and browser runtime

## Context

ADR-0007 introduced a small Opal-owned wire protocol and DOM client. That
proved the Crystal lifecycle, but made Opal responsible for reconnect, BFCache,
history, form recovery, DOM patching, hooks, loading states, and every browser
edge case already handled by Phoenix LiveView.

The release goal is to reuse the tested browser implementation while keeping
the server, application API, dependency injection, guards, and lifecycle in
Crystal. Application projects must not need an Elixir/Phoenix runtime or their
own npm pipeline.

## Decision

Opal pins `phoenix` 1.8.13 and `phoenix_live_view` 1.2.11 during Opal's asset
build. The resulting ES module is committed, embedded in the shard, and served
from `/_opal/live.js`. Applications consume that asset without Node.js.

`LF::LiveView::Endpoint` implements a bounded Phoenix Channels and LiveView
server contract:

- serializer-v2 arrays, `phx_join`, `phx_reply`, leave, and heartbeat;
- LiveView mount responses and pushed/event-reply diffs;
- structural statics and numeric dynamics;
- keyed-comprehension native stream inserts, deletes, reset, position, and limit;
- titles, hook replies, pushed browser events, and component-only `c` diffs;
- `live_patch` and `live_redirect` with current-URL reconnect mounts.

The client uses the supported `bindingPrefix: "data-opal-"`, preserving
`data-opal-click`, change, submit, debounce, value, target, and hook bindings.
Phoenix's hard-coded live-link attributes remain `data-phx-link` and
`data-phx-link-state`. The endpoint is configured at `/_opal/live`; Phoenix
opens its transport at `/_opal/live/websocket?vsn=2.0.0`.

The signed mount value establishes route identity. On every join, including
reconnect after history or BFCache restoration, the server validates the
current URL against that route and derives fresh route/query parameters from
the URL. Authorization still runs for disconnected mount, connected mount,
and every live patch.

## Consequences

Opal deletes its custom browser patcher, event queue, heartbeat, history, hook,
and reconnect implementation. Browser lifecycle behavior now follows the
pinned upstream release, and Chromium tests exercise the bundled artifact.

Opal remains responsible for a compatible server subset and must pin client
upgrades deliberately. Asset generation is reproducible through
`npm run build:live-view-client`; `npm run check:live-view-client` detects an
out-of-date committed bundle.

Uploads, general application-facing template/comprehension tables, nested child
LiveViews, and same-socket navigation across page classes are outside the
initial subset. Uploads are intentionally not planned. Unsupported channel
events return an explicit error reply.
