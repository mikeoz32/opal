# Opal LiveView Counter

This example is a complete interactive page using Opal's Crystal LiveView
server and the prebundled upstream Phoenix LiveView browser runtime. The
example application itself needs neither Elixir/Phoenix nor npm.

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
- Phoenix structural diffs and upstream focused-input preservation;
- native keyed-comprehension list reordering without recreating DOM nodes;
- native component-only diffs, parent-scoped nested state, and deep targeted
  events;
- native Phoenix stream insertion, deletion, limits, and retained DOM identity;
- client- and server-driven live patches, history, and fresh-page navigation;
- opt-in JavaScript hook lifecycle, event replies, targeted component events,
  and server-pushed browser events;
- dynamic document titles and automatic reconnect;
- automatic HTML escaping for structured template values.

The development secret in `config/application.yml` is intentionally local to
the example. Generate and inject a private secret of at least 32 bytes in real
deployments.
