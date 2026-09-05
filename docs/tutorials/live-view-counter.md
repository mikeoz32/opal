# Tutorial: your first LiveView page

The [`examples/live_view_counter`](https://github.com/mikeoz32/opal/tree/main/examples/live_view_counter)
application is the executable version of this tutorial. It runs a server-owned
counter with no Elixir, Phoenix application, or per-project JavaScript build.

## 1. Declare a page

Load HTTP autoconfiguration and make a `View` subclass a route with
`@[LF::LiveView::Page]`:

```crystal
require "opal"
require "opal/autoconfig/http"

@[LF::LiveView::Page("/counter")]
class CounterLive < LF::LiveView::View
  @count = 0

  def handle_event(event : String, value : JSON::Any) : Nil
    case event
    when "increment" then @count += 1
    when "decrement" then @count -= 1
    else super
    end
  end

  def render : LF::LiveView::Rendered
    LF::LiveView::HTML.rendered(<<-HTML)
      <button phx-click="decrement">-</button>
      <output id="counter-value">#{@count}</output>
      <button phx-click="increment">+</button>
    HTML
  end
end
```

Use standard `phx-*` binding names. Opal bundles pinned upstream Phoenix and
Phoenix LiveView browser packages, so focused inputs, reconnection, DOM
patching, form recovery, and client-side navigation follow that established
browser contract.

## 2. Create the application

```crystal
@[LF::Application]
@[LF::AutoConfig::HTTP]
class CounterApplication
end

CounterApplication.run_http
```

Configure HTTP and a secret of at least 32 bytes:

```yaml
http:
  host: 127.0.0.1
  port: 8080

live_view:
  secret: replace-with-a-generated-production-secret
```

Start the application, open `http://127.0.0.1:8080/counter`, and press a
button. The initial response is HTML; the page then connects through an Opal
WebSocket endpoint and receives server-rendered updates.

## 3. Know the lifecycle boundary

`mount` runs once for the disconnected initial render and again after the
socket connects. Treat client event values as untrusted input and repeat
authorization in connected `mount`.

```crystal
def mount(context : LF::LiveView::MountContext) : Nil
  @connected = context.connected?
end
```

For a complete lifecycle, live navigation, keyed rendering, components,
streams, JavaScript hooks, and server-initiated messages, continue to the
[LiveView guide](../live-view.md).
