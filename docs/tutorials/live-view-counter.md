# Tutorial: your first LiveView page

The [`examples/live_view_counter`](https://github.com/mikeoz32/opal/tree/main/examples/live_view_counter)
application is the executable version of this tutorial. It runs a server-owned
counter with no Elixir, Phoenix application, or per-project JavaScript build.

## 1. Declare a page

Load HTTP autoconfiguration and make a `View` subclass a route with
`@[LF::LiveView::Page]`:

```crystal
--8<-- "examples/documentation/live_view_counter.cr:imports"

--8<-- "examples/documentation/live_view_counter.cr:view_start"
--8<-- "examples/documentation/live_view_counter.cr:mount"
--8<-- "examples/documentation/live_view_counter.cr:view_end"
```

Use standard `phx-*` binding names. Opal bundles pinned upstream Phoenix and
Phoenix LiveView browser packages, so focused inputs, reconnection, DOM
patching, form recovery, and client-side navigation follow that established
browser contract.

## 2. Create the application

```crystal
--8<-- "examples/documentation/live_view_counter.cr:application"
```

Save the HTTP configuration and a secret of at least 32 bytes as
`config/application.yml`:

```yaml
http:
  host: 127.0.0.1
  port: 8080

live_view:
  secret: replace-with-a-generated-production-secret
```

Start the application with `crystal run src/app.cr`, open
`http://127.0.0.1:8080/counter`, and press a button. To keep configuration in a
different location, set `OPAL_CONFIG=/path/to/application.yml`. The initial
response is HTML; the page then connects through an Opal WebSocket endpoint and
receives server-rendered updates.

## 3. Know the lifecycle boundary

`mount` runs once for the disconnected initial render and again after the
socket connects. Treat client event values as untrusted input and repeat
authorization in connected `mount`.

```crystal
--8<-- "examples/documentation/live_view_counter.cr:mount"
```

For a complete lifecycle, live navigation, keyed rendering, components,
streams, JavaScript hooks, and server-initiated messages, continue to the
[LiveView guide](../live-view.md).
