# Opal LiveView

Opal LiveView provides server-rendered, event-driven pages over Opal's native
WebSocket layer. It has its own protocol and dependency-free browser client;
projects do not install Phoenix packages or configure an npm build.

## Minimal application

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
      <button data-opal-click="decrement">-</button>
      <output id="counter-value">#{@count}</output>
      <button data-opal-click="increment">+</button>
    HTML
  end
end

@[LF::Application]
@[LF::AutoConfig::HTTP]
class MyApplication
end

MyApplication.run_http
```

Configure a secret of at least 32 bytes:

```yaml
http:
  host: 127.0.0.1
  port: 8080

live_view:
  secret: replace-with-a-generated-production-secret
```

Opal serves the initial document, browser module, and socket endpoint. See
`examples/live_view_counter` for constructor DI, query params, click events,
debounced form changes, form submit, title updates, and escaped values.

## Lifecycle

`mount` runs for the initial HTTP render and again for the connected socket:

```crystal
def mount(context : LF::LiveView::MountContext) : Nil
  @connected = context.connected?
  @filter = context.query_params["filter"]? || "all"
  @project_id = context.params["project_id"]
  authorize!(context.request, @project_id)
end
```

Always repeat authentication and authorization in connected mount. The signed
mount token makes route state tamper-evident; it does not grant access by
itself. On reconnect, a fresh view is mounted from the signed original URL and
current handshake request. Persist state that must survive reconnect in an
application service or database.

HTTP guards can be declared directly on the view. Application-level guards
also apply. Opal evaluates them for both the disconnected and connected mount:

```crystal
@[LF::HTTP::UseGuards(AuthenticatedGuard)]
@[LF::LiveView::Page("/projects/:project_id")]
class ProjectLive < LF::LiveView::View
end
```

Mount guards protect access to the page. Continue authorizing resource-specific
operations inside `handle_event`; browser event payloads are untrusted input.

## Events and forms

Click values use `data-opal-value-*`:

```html
<button data-opal-click="delete" data-opal-value-id="42">Delete</button>
```

The event receives a JSON object:

```crystal
def handle_event(event : String, value : JSON::Any) : Nil
  case event
  when "delete"
    @todos.delete(value.as_h["id"].as_s.to_i64)
  else
    super
  end
end
```

Forms serialize successful fields by name. Repeated names become arrays:

```html
<form data-opal-change="validate"
      data-opal-debounce="200"
      data-opal-submit="save">
  <input name="title" value="...">
  <button type="submit">Save</button>
</form>
```

`data-opal-change` reacts to `change`, or debounced `input` when
`data-opal-debounce` is present. Protocol v2 morphs matching DOM nodes instead
of replacing the live root. Focused input values and selections remain
browser-owned while the event is in flight.

## Server-initiated updates

Events rerender automatically. A timer or subscription must not mutate view
state from its own fiber. Send an info message back to the connection fiber:

```crystal
include LF::DI::Disposable

@stop = Channel(Nil).new

def mount(context : LF::LiveView::MountContext) : Nil
  return unless context.connected?
  spawn do
    loop do
      select
      when @stop.receive?
        break
      when timeout(1.second)
        send_info("tick", JSON::Any.new(Time.local.to_unix))
      end
    end
  end
end

def handle_info(name : String, value : JSON::Any) : Nil
  case name
  when "tick"
    @clock = Time.unix(value.as_i64)
  else
    super
  end
end

def destroy : Nil
  @stop.close unless @stop.closed?
end
```

Info callbacks, events, renders, and outbound writes are serialized on the
connection fiber. Stop subscriptions and timers from
`LF::DI::Disposable#destroy` when the WebSocket scope exits.

## Rendering safely

Use `LF::LiveView::HTML.rendered` for structural rendering. Literal fragments
become the stable template and interpolated values are escaped automatically:

```crystal
def render : LF::LiveView::Rendered
  LF::LiveView::HTML.rendered(%(<li id="todo-#{@todo.id}">#{@todo.title}</li>))
end
```

When the template fingerprint stays the same, Opal sends only changed dynamic
positions. Returning `String` remains supported, but it is an opaque
compatibility render: any HTML change requires a complete snapshot.

`HTML.raw` is the explicit escape hatch for framework- or application-owned
markup. Never pass user-controlled HTML to it:

```crystal
LF::LiveView::HTML.rendered(%(<ul>#{LF::LiveView::HTML.raw(trusted_items)}</ul>))
```

The browser reuses compatible elements by position. Give elements stable `id`
or `data-opal-key` values when identity must survive insertion or reordering:

```html
<li data-opal-key="todo-42">...</li>
```

## Stateful components

Subclass `LF::LiveView::Component` when multiple independently stateful pieces
share one LiveView connection. A component identity is its concrete type plus
the `id` passed to `live_component`. Its `mount` callback runs once for that
identity, `update` receives the current parent assigns before every render, and
targeted events run on the component instead of the parent view:

```crystal
class CounterComponent < LF::LiveView::Component
  @count = 0
  @label = ""

  def update(assigns : JSON::Any) : Nil
    @label = assigns.as_h["label"].as_s
  end

  def handle_event(event : String, value : JSON::Any) : Nil
    event == "increment" ? @count += 1 : super
  end

  def render : LF::LiveView::Rendered
    LF::LiveView::HTML.rendered(<<-HTML)
      <section id="counter-#{id}" data-opal-target="#{myself}">
        <span>#{@label}: #{@count}</span>
        <button data-opal-click="increment">+</button>
      </section>
    HTML
  end
end
```

Render each instance from the parent with a stable id:

```crystal
def render : LF::LiveView::Rendered
  left = live_component(CounterComponent, "left", {label: "Left"}) do
    CounterComponent.new
  end
  right = live_component(CounterComponent, "right", {label: "Right"}) do
    CounterComponent.new
  end

  LF::LiveView::HTML.rendered(%(<div>#{left}#{right}</div>))
end
```

`data-opal-target="#{myself}"` may be placed on the event element or any
ancestor inside the component. The browser sends the connection-local target
with click, change, and submit events. Events without a target continue to run
`View#handle_event`.

A component disappears when the parent stops rendering its identity. Opal then
forgets its state and calls `destroy` when the component includes
`LF::DI::Disposable`; rendering that identity again creates a fresh instance.
All remaining components are destroyed when their LiveView disconnects.

## Streams

Streams update large or frequently changing collections without retaining and
rerendering the whole collection in the connected view. The browser owns the
current children of a container with a unique `id` and `data-opal-stream`.
Queue initial operations from `mount` and expose them to the disconnected HTML
render with `stream_contents`:

```crystal
def mount(context : LF::LiveView::MountContext) : Nil
  stream_reset("notifications")
  @notifications.each do |notification|
    id = "notification-#{notification.id}"
    stream_insert("notifications", id, notification_item(id, notification))
  end
end

def render : LF::LiveView::Rendered
  notifications = stream_contents("notifications")
  LF::LiveView::HTML.rendered(
    %(<ul id="notifications" data-opal-stream>#{notifications}</ul>)
  )
end

private def notification_item(id, notification) : LF::LiveView::Rendered
  LF::LiveView::HTML.rendered(%(<li id="#{id}">#{notification.message}</li>))
end
```

Each inserted item must have exactly one root element whose DOM `id` matches
the item id passed to `stream_insert`. Queue mutations from `handle_event`,
`handle_info`, or another serialized lifecycle callback:

```crystal
stream_insert("notifications", id, item)                 # append or update
stream_insert("notifications", id, item, at: 0)          # prepend
stream_insert("notifications", id, item, at: 0, limit: 20)
stream_delete("notifications", id)
stream_reset("notifications")
```

Inserting an existing id morphs that item in place and preserves its position.
For new items, `at: -1` appends and a non-negative index inserts at that
position. A positive `limit` retains the first N children; a negative limit
retains the last N. Reset is useful when a fresh connected mount or reconnect
must replace browser-owned collection state with a canonical snapshot.

Do not also render ordinary dynamic children inside a stream container. Normal
LiveView morphing deliberately preserves that container's children; only
validated stream operations may insert, update, delete, or reset them. Streams
are a protocol-v2 feature. A view that queues stream operations rejects a
legacy protocol-v1 connection instead of sending an incomplete collection.

The mount token and built-in document metadata are escaped by the endpoint.
Opal does not add event values or tokens to log metadata. Do not put secrets in
application exception messages.

### Custom document layout

Override `render_document` when the page needs an application layout. Keep both
framework arguments in the returned document:

```crystal
def render_document(live_root : String, client_script : String) : String
  "<!doctype html><html><body><nav>My app</nav>#{live_root}#{client_script}</body></html>"
end
```

## Configuration

```yaml
live_view:
  secret: at-least-32-bytes-and-kept-private
  socket_path: /_opal/live
  client_path: /_opal/live.js
  mount_token_max_age_ms: 86400000
  max_message_bytes: 65536
  join_timeout_ms: 10000
  idle_timeout_ms: 75000
  allowed_origins:
    - https://app.example.com
```

When `allowed_origins` is omitted, the endpoint requires the browser `Origin`
to match the request `Host`. Use an allowlist only when proxy topology makes
the default inappropriate.

## Manual assembly

Without Application autoconfiguration, create an endpoint, register factories,
and mount it into the router. The WebSocket scope handler must precede the
request scope handler:

```crystal
root = LF::DI::DefaultContainer.new
connections = LF::HTTP::WebSocketConnectionRegistry.new
endpoint = LF::LiveView::Endpoint.new(ENV["LIVE_VIEW_SECRET"])
endpoint.page("/counter", CounterLive) { |_scope| CounterLive.new }

app = LF::HTTP::App.new { |router| endpoint.mount(router) }
server = HTTP::Server.new([
  LF::HTTP::DI::WebSocketScopeHandler.new(root, "websocket", connections),
  LF::HTTP::DI::RequestScopeHandler.new(root),
  app,
])

begin
  server.listen
ensure
  server.close unless server.closed?
  connections.shutdown(5_000)
  root.shutdown
end
```

Factories created directly by `Endpoint#page` are endpoint-owned and are
destroyed after their disconnected or connected lifecycle when they implement
`LF::DI::Disposable`. Autoconfigured views are container-owned instead.

## Protocol compatibility and current boundary

The built-in client negotiates protocol v2. The first connected render carries
the template fingerprint, static fragments, and dynamic values. Later renders
with the same fingerprint carry only changed dynamic positions; a changed
template or legacy `String` render sends a complete v2 snapshot. The server
continues accepting protocol-v1 clients and returns their complete `html`
payloads.

Protocol v2 provides connection-local stateful components, component-targeted
events, and browser-owned streams. It does not yet provide nested components,
upload transport, live navigation, or JavaScript hooks. These features can
evolve under Opal's protocol without introducing a Phoenix dependency.
