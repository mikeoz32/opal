# Opal LiveView

Opal LiveView provides server-rendered, event-driven pages over Opal's native
WebSocket layer. The browser runtime is the pinned upstream Phoenix 1.8.13 and
Phoenix LiveView 1.2.11 client, prebundled into the shard. Application projects
do not install Phoenix, Elixir, Node.js, or configure an asset build for the
default client.

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
  @project_id = context.params["project_id"]
  authorize!(context.request, @project_id)
end

def handle_params(context : LF::LiveView::ParamsContext) : Nil
  @filter = context.query_params["filter"]? || "all"
  @project_id = context.params["project_id"]
end
```

`handle_params` runs after each disconnected and connected mount, and again
after every live patch. Route parameters are available through `params`; query
parameters are available through `query_params`.

Always repeat authentication and authorization in connected mount. The signed
mount token makes the route identity tamper-evident; it does not grant access
by itself. On connect and reconnect, Opal validates the browser's current URL
against that signed route and derives current path/query parameters from the
URL. Persist other state that must survive reconnect in an application service
or database.

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
`data-opal-debounce` is present. These names are retained through LiveSocket's
supported `bindingPrefix`; DOM patching, focused controls, debounce/throttle,
loading states, reconnect, and form recovery are handled by upstream
`phoenix_live_view`.

## JavaScript hooks and custom events

Use an opt-in hook for browser APIs or third-party widgets that cannot be
expressed as server-rendered HTML. Every hook element must have a unique,
stable DOM `id`:

```html
<div id="sales-chart" data-opal-hook="SalesChart"></div>
```

Define the registry before Opal's client module loads. A custom
`render_document` can place an application-owned script immediately before the
provided `client_script`:

```javascript
globalThis.OpalLiveViewHooks = {
  SalesChart: {
    mounted() {
      this.subscription = this.handleEvent("chart-points", points => {
        this.chart.add(points)
      })
    },
    beforeUpdate(toEl) {
      // Synchronously copy browser-owned attributes to the incoming element.
      toEl.dataset.zoom = this.el.dataset.zoom
    },
    updated() {},
    disconnected() {},
    reconnected() {},
    destroyed() {
      this.removeHandleEvent(this.subscription)
      this.chart.destroy()
    }
  }
}
```

Supported callbacks and hook APIs are the upstream Phoenix LiveView contract,
including `mounted`, `beforeUpdate`, `updated`, `destroyed`, `disconnected`,
`reconnected`, `pushEvent`, `pushEventTo`, `handleEvent`, and
`removeHandleEvent`.

With no callback, `pushEvent` returns a promise resolving directly to the
server reply; with a callback, the callback receives `(reply, ref)`.
`pushEventTo` accepts a selector, DOM element, or component CID:

```javascript
const reply = await this.pushEvent("lookup", {query: "opal"})
const results = await this.pushEventTo("#todo-42", "archive", {})
```

A view or component can reply once from its current event callback and enqueue
events for browser hooks:

```crystal
def handle_event(event : String, value : JSON::Any) : Nil
  case event
  when "lookup"
    result = search(value.as_h["query"].as_s)
    push_event("search-result", result)
    reply({accepted: true, count: result.size})
  else
    super
  end
end
```

Pushed events run after the associated DOM patch. Every active hook registered
through `handleEvent` receives the event, and the browser also dispatches the
standard window event `phx:<event>`. A fresh-document navigation intentionally
does not deliver queued events to hooks from the page being replaced.

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

Each disconnected or connected view has its own internal
`LF::LiveView::ConnectionRuntime`. It owns component, stream, navigation, and
client-event infrastructure for that lifecycle; application `View` subclasses
contain only their page state and callbacks. The runtime is connection-scoped,
not an application-wide extension, so mutable state is never shared between
separate sockets.

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
values when identity must survive insertion or reordering:

```html
<li id="todo-42">...</li>
```

## Stateful components

Subclass `LF::LiveView::Component` when multiple independently stateful pieces
share one LiveView connection. At the view root, a component identity is its
concrete type plus the `id` passed to `live_component`. Nested identities also
include the parent component instance, so separate parents can safely reuse the
same child type and id. A component's `mount` callback runs once for that
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
      <section id="counter-#{id}">
        <span>#{@label}: #{@count}</span>
        <button data-opal-click="increment" data-opal-target="#{myself}">+</button>
      </section>
    HTML
  end
end
```

Opal adds the upstream `data-phx-component` and `data-phx-view` ownership
markers to the component root. Put `data-opal-target="#{myself}"` on each
binding that should dispatch to the component; targets are not inherited from
an ancestor element.

Connected renders use Phoenix's native top-level `c` component table. The
parent tree carries only the numeric CID, while changed component dynamics are
sent independently. A targeted component event therefore patches only that
component root; unchanged siblings and the parent DOM are not serialized or
morphed. New and nested components receive full rooted component entries, and
subsequent renders send only their changed dynamic positions.

Components can render stateful children with the same protected helper. For
example, every panel below owns an independent `CounterComponent` whose local
id is `"counter"`:

```crystal
class PanelComponent < LF::LiveView::Component
  @label = ""

  def update(assigns : JSON::Any) : Nil
    @label = assigns.as_h["label"].as_s
  end

  def render : LF::LiveView::Rendered
    counter = live_component(CounterComponent, "counter", {label: @label}) do
      CounterComponent.new
    end
    LF::LiveView::HTML.rendered(%(<section>#{counter}</section>))
  end
end
```

`live_component` is valid only while the receiving view or component is in its
own `render` callback. Repeating an identity within the same parent render is
an error. Repeating the same type and id in its own ancestry is rejected as a
recursive component cycle, and nesting is bounded to
`LF::LiveView::View::MAX_COMPONENT_DEPTH` levels.

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

Place `data-opal-target="#{myself}"` on each click, change, or submit binding
that belongs to the component. Upstream LiveView does not inherit a target
from an ancestor. Events without a target continue to run `View#handle_event`.

A component disappears when the parent stops rendering its identity. Opal then
forgets its state and calls `destroy` when the component includes
`LF::DI::Disposable`; rendering that identity again creates a fresh instance.
Removing a parent recursively removes its descendants and destroys children
before their parent. All remaining component trees are destroyed in the same
order when their LiveView disconnects.
Components may also call protected `push_patch` and `push_navigate` from their
event callbacks; navigation is serialized through their parent connection.
They may also call `push_event` and `reply` for hook interoperability.

## Child LiveViews

Use a child LiveView when a subtree needs a complete LiveView lifecycle and an
independent event queue, rather than only connection-local component state.
Child classes are ordinary `View` subclasses without a `Page` annotation:

```crystal
class ActivityLive < LF::LiveView::View
  @project_id = ""

  def mount(context : LF::LiveView::MountContext) : Nil
    @project_id = context.session.as_h["project_id"].as_s
  end

  def render : LF::LiveView::Rendered
    LF::LiveView::HTML.rendered(
      %(<section id="activity">Project #{@project_id}</section>)
    )
  end
end
```

Render it from a parent View or stateful Component with a document-unique id,
a JSON-serializable mount session, and a factory:

```crystal
activity = live_view(ActivityLive, "project-activity", {project_id: @project_id}) do
  ActivityLive.new
end

LF::LiveView::HTML.rendered(%(<main>#{activity}</main>))
```

Disconnected HTTP rendering mounts and renders the complete child tree. Once
connected, Phoenix.js joins `lv:project-activity` on the existing WebSocket.
The child then owns its state, events, `send_info`, components, streams, hooks,
pushed events, and diffs independently. Child LiveViews may render further
children; nesting is bounded to 32 levels.

Rerendering the parent with the same child id preserves the connected child DOM
and state. Removing the id makes Phoenix leave that child and its descendants;
rendering it again creates fresh instances. Factory-created child views that
include `LF::DI::Disposable` receive `destroy` after disconnect. Child ids must
be unique across the document, and a live id cannot change its view type.

`MountContext#session`, `#parent_id`, and `#view_id` identify a child mount.
Child views are not router pages, so they do not run `handle_params` and cannot
own `live_patch`; use `push_navigate` for a fresh-page destination or let the
root view own URL patches. Each child session is signed with its parent/topic,
type, id, resource, and nesting depth before a join is accepted.

## Keyed comprehensions

Use `HTML.keyed` for an application-owned collection whose retained entries
should move or update without being resent or recreated. Return a stable key
and one `Rendered` item from the block:

```crystal
rows = LF::LiveView::HTML.keyed(@projects) do |project|
  {
    project.id,
    LF::LiveView::HTML.rendered(
      %(<li id="project-#{project.id}">#{project.name}</li>)
    ),
  }
end

LF::LiveView::HTML.rendered(%(<ul id="projects">#{rows}</ul>))
```

Every item must use the same static template and every key must be unique in
that render. Keys are server-side identities and do not replace useful DOM
ids. Connected updates use Phoenix's native `s`/`k`/`kc` representation:
unchanged entries are referenced by their previous index, `km` marks a move,
and moved entries with changed dynamics carry `[previous_index, diff]`.
Additions send only the new entry dynamics, removals reduce `kc`, and an empty
collection is valid.

Use keyed comprehensions when the application owns the whole current list.
Use streams when mutations should be queued as inserts/deletes and the server
should not resend retained entries at all.

## Streams

The stream API maintains large or frequently changing ordered collections in
the connection runtime instead of application view fields. Give the container
a unique `id` and set `data-opal-update="stream"`; the binding prefix maps this
to Phoenix LiveView's native stream DOM behavior. Queue initial operations from
`mount` and expose the collection with `stream_contents`:

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
    %(<ul id="notifications" data-opal-update="stream">#{notifications}</ul>)
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
stream_insert("notifications", id, item, update_only: true)
stream_delete("notifications", id)
stream_reset("notifications")
```

Inserting an existing id morphs that item in place and preserves its position.
For new items, `at: -1` appends and a non-negative index inserts at that
position. A positive `limit` retains the first N children; a negative limit
retains the last N. `update_only: true` updates an existing browser item but
does not insert it when absent. Reset is useful when a fresh connected mount or
reconnect must replace the collection with a canonical snapshot.

Each connected diff contains the upstream keyed-comprehension `s`/`k`/`kc`
shape and `stream` metadata tuple. Only inserted or updated item HTML plus
delete/reset metadata crosses the socket; retained items are not resent. The
runtime keeps a canonical snapshot for disconnected rendering, reconnect, and
rollback when an event is rejected. It also rejects duplicate stream
consumption, pending operations omitted from the render, and item markup whose
root `id` does not match the declared stream item id.

## Live navigation

Use the standard Phoenix live-link attributes to change route or query
parameters without remounting the current LiveView:

```html
<a href="/projects/42?tab=activity"
   data-phx-link="patch" data-phx-link-state="push">Activity</a>
<a href="/projects/42?tab=settings"
   data-phx-link="patch" data-phx-link-state="replace">Settings</a>
```

The target path must match the current `@[Page]` route. Opal reruns route and
application guards with action `"patch"`, calls `handle_params`, and replies
with a Phoenix diff. Upstream LiveView commits `pushState` or `replaceState`
only after the acknowledgement and owns browser back/forward handling.

A view or stateful component can initiate the same operations from an event or
info callback:

```crystal
push_patch("/projects/42?tab=activity")
push_patch("/projects/42?tab=settings", replace: true)
push_navigate("/projects")
```

`push_navigate` performs an upstream `live_redirect`. Ordinary local links
perform a fresh document mount. Opal deliberately does not keep the current
socket across page classes until it has an explicit, guardable equivalent of
Phoenix `live_session`.
External, scheme-relative, credential-bearing, fragment, and cross-route patch
targets are never accepted as live patches. Ordinary links remain available
for fragment and external navigation.

The upstream client owns navigation events, pagehide/pageshow handling, BFCache
restore, heartbeat, and reconnect. A reconnect sends the current browser URL,
so path and query state cannot fall back to the original mount URL.

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

Phoenix leaves an existing title unchanged when a pushed title is blank unless
the document title declares a default. Use `<title data-default="">...</title>`
when an explicit empty `View#title` should clear it.

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

The endpoint implements a tested subset of Phoenix Channels serializer v2 and
Phoenix LiveView 1.2.11: `phx_join`, `phx_reply`, heartbeat, `event`,
`live_patch`, `live_redirect`, pushed `diff`, structural statics/dynamics,
titles, hook replies/events, and component CIDs. The independent Opal protocol
and browser DOM runtime are removed.

Current server gaps are shared template tables and same-socket navigation
across page classes. Uploads are intentionally outside the current roadmap.
Unsupported channel events receive an error reply; they are not silently
treated as implemented.
Applications consume the bundled asset and therefore need no JavaScript build,
while Opal's own release process pins and rebuilds the upstream npm packages.
