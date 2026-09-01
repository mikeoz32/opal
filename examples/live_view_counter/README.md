# Opal LiveView Counter

This example is a complete interactive page using Opal's own LiveView server
and browser runtime. It has no Phoenix or npm dependency.

From this directory:

```bash
shards install
crystal spec --no-color
crystal run src/live_view_counter_example.cr
```

Open <http://127.0.0.1:8084/?start=2>. The example demonstrates:

- disconnected HTTP and connected WebSocket mounts;
- constructor injection into a connection-scoped view;
- query-parameter initialization;
- click events and server-owned counter state;
- debounced form changes and form submit;
- a delayed server-side state change using serialized `send_info`;
- protocol-v2 structural diffs and focused input preservation;
- keyed list reordering without recreating DOM nodes;
- parent-scoped nested stateful components with isolated state and deep targeted
  events;
- bounded browser-owned stream insertion and deletion;
- client- and server-driven live patches, history, and fresh-page navigation;
- opt-in JavaScript hook lifecycle, event replies, targeted component events,
  and server-pushed browser events;
- dynamic document titles and automatic reconnect;
- automatic HTML escaping for structured template values.

The development secret in `config/application.yml` is intentionally local to
the example. Generate and inject a private secret of at least 32 bytes in real
deployments.
