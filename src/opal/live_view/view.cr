require "http/request"
require "json"
require "uri"
require "./connection_runtime"
require "./html"

module LF::LiveView
  annotation Page
  end

  class ParamsContext
    getter params : Hash(String, String)
    getter uri : URI

    def initialize(@params, resource : String)
      @uri = URI.parse(resource)
    end

    def query_params : URI::Params
      @uri.query_params
    end
  end

  class MountContext < ParamsContext
    getter request : ::HTTP::Request
    getter? connected : Bool
    getter session : JSON::Any
    getter parent_id : String?
    getter view_id : String

    def initialize(
      @request,
      params : Hash(String, String),
      resource : String,
      @connected,
      @session = JSON::Any.new(nil),
      @parent_id = nil,
      @view_id = "opal-live-root",
    )
      super(params, resource)
    end
  end

  # Base class for one server-owned LiveView page instance.
  #
  # Opal creates a disconnected instance for the initial HTTP render and a
  # distinct connected instance for the WebSocket lifecycle. State belongs to
  # that instance, not to the view class or an application singleton. Browser
  # event payloads are untrusted and authorization must be repeated in connected
  # `#mount`.
  abstract class View
    ROOT_COMPONENT_CID  = ConnectionRuntime::ROOT_COMPONENT_CID
    MAX_COMPONENT_DEPTH = ConnectionRuntime::MAX_COMPONENT_DEPTH

    @runtime = ConnectionRuntime.new

    # Runs after each disconnected or connected view instance is created.
    # `context.connected?` distinguishes the WebSocket lifecycle from the
    # initial HTML render.
    def mount(context : MountContext) : Nil
    end

    # Runs after mount and whenever a live patch changes the current route or
    # query parameters without replacing this view instance.
    def handle_params(context : ParamsContext) : Nil
    end

    # Returns structural `Rendered` HTML or a compatible string render. Prefer
    # `HTML.rendered` so Opal can retain a stable template and update only
    # changed dynamic positions.
    abstract def render : RenderResult

    # Handles a browser `phx-*` event on the connection fiber. Override this
    # method and call `super` for unknown events to preserve the error contract.
    def handle_event(event : String, value : JSON::Any) : Nil
      raise UnknownEventError.new(event)
    end

    def handle_info(name : String, value : JSON::Any) : Nil
      raise UnknownInfoError.new(name)
    end

    def title : String?
      nil
    end

    # Override this to wrap the live root in an application-owned document.
    # Both arguments already contain trusted framework markup and must remain in
    # the returned document for the page to connect.
    def render_document(live_root : String, client_script : String) : String
      document_title = HTML.escape(title || "Opal LiveView")
      String.build do |html|
        html << "<!doctype html><html><head><meta charset=\"utf-8\">"
        html << "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
        html << "<link rel=\"icon\" href=\"data:,\">"
        html << "<title>" << document_title << "</title></head><body>"
        html << live_root << client_script << "</body></html>"
      end
    end

    # Enqueues an application message on the LiveView connection fiber. Use
    # this from timers and subscriptions instead of mutating view state from
    # their fibers directly.
    protected def send_info(name : String, value = JSON::Any.new(nil)) : Bool
      @runtime.send_info(Info.new(name, value))
    end

    # Schedules one coalesced render when state was changed by code already
    # running on the LiveView connection fiber.
    protected def refresh : Bool
      @runtime.refresh
    end

    # Changes the URL inside this LiveView without remounting it.
    protected def push_patch(to : String, *, replace : Bool = false) : Nil
      @runtime.navigate(Navigation.patch(to, replace: replace))
    end

    # Navigates through a fresh HTTP mount. Opal does not yet define
    # cross-view live sessions, so this intentionally replaces the document.
    protected def push_navigate(to : String, *, replace : Bool = false) : Nil
      @runtime.navigate(Navigation.navigate(to, replace: replace))
    end

    # Delivers an application event to browser hooks after the next DOM patch.
    protected def push_event(name : String, payload : JSON::Any = JSON::Any.new(nil)) : Nil
      @runtime.push_event(PushedEvent.new(name, payload))
    end

    protected def push_event(name : String, payload) : Nil
      push_event(name, JSON.parse(payload.to_json))
    end

    # Replies to the client event currently being handled. At most one reply
    # may be produced by an event callback.
    protected def reply(value : JSON::Any = JSON::Any.new(nil)) : Nil
      @runtime.reply(value)
    end

    protected def reply(value) : Nil
      reply(JSON.parse(value.to_json))
    end

    # Renders a stateful component. Reusing the same component type and id on
    # later renders reuses its connection-local state. Assigns must be JSON
    # serializable and are delivered to `Component#update` before each render.
    protected def live_component(
      type : T.class,
      id : String,
      assigns : JSON::Any = JSON::Any.new(nil),
      &factory : -> T
    ) : Rendered forall T
      component_factory = -> { factory.call.as(Component) }
      @runtime.render_component(T.name, id, assigns, component_factory)
    end

    protected def live_component(
      type : T.class,
      id : String,
      assigns,
      &factory : -> T
    ) : Rendered forall T
      live_component(type, id, JSON.parse(assigns.to_json), &factory)
    end

    # Renders a child LiveView with its own channel and lifecycle on the same
    # Phoenix socket. The id must be unique within the document.
    protected def live_view(
      type : T.class,
      id : String,
      session : JSON::Any = JSON::Any.new(nil),
      &factory : -> T
    ) : ChildViewContent forall T
      child_factory = -> { factory.call.as(View) }
      @runtime.render_child_view(T.name, id, session, child_factory)
    end

    protected def live_view(
      type : T.class,
      id : String,
      session,
      &factory : -> T
    ) : ChildViewContent forall T
      live_view(type, id, JSON.parse(session.to_json), &factory)
    end

    # Queues an insert or update in a browser-owned stream container. New items
    # are appended by default; `at: 0` prepends. A positive limit keeps the
    # first N elements and a negative limit keeps the last N elements.
    protected def stream_insert(
      container_id : String,
      item_id : String,
      rendered : RenderResult,
      *,
      at : Int32 = -1,
      limit : Int32? = nil,
      update_only : Bool = false,
    ) : Nil
      @runtime.stream_insert(
        container_id,
        item_id,
        rendered,
        at: at,
        limit: limit,
        update_only: update_only
      )
    end

    # Queues removal of one direct child from a browser-owned stream container.
    protected def stream_delete(container_id : String, item_id : String) : Nil
      @runtime.stream_delete(container_id, item_id)
    end

    # Queues removal of every child in a browser-owned stream container.
    protected def stream_reset(container_id : String) : Nil
      @runtime.stream_reset(container_id)
    end

    # Renders the current stream contents into the normal LiveView tree. Stream
    # item markup is already trusted framework output and is not escaped again.
    protected def stream_contents(container_id : String) : StreamContent
      @runtime.stream_contents(container_id)
    end

    # :nodoc:
    def __opal_mount(context : MountContext) : Nil
      @runtime.prepare_mount(context.connected?)
      mount(context)
    end

    # :nodoc:
    def __opal_connect(
      send_info : Proc(Info, Bool),
      refresh : Proc(Bool),
    ) : Nil
      @runtime.connect(send_info, refresh)
    end

    # :nodoc:
    def __opal_configure_child_views(
      renderer : ConnectionRuntime::ChildViewRenderer,
      finish : Proc(Set(String), Nil),
    ) : Nil
      @runtime.configure_child_views(renderer, finish)
    end

    # :nodoc:
    def __opal_disconnect : Nil
      @runtime.disconnect
    end

    # :nodoc:
    def __opal_render : Rendered
      @runtime.render { render }
    end

    # :nodoc:
    def __opal_handle_event(target : Int64?, event : String, value : JSON::Any) : EventReply?
      @runtime.handle_event(target, event, value) { handle_event(event, value) }
    end

    # :nodoc:
    def __opal_handle_params(context : ParamsContext) : Nil
      handle_params(context)
    end

    # :nodoc:
    def __opal_take_navigation : Navigation?
      @runtime.take_navigation
    end

    # :nodoc:
    def __opal_clear_navigation : Nil
      @runtime.clear_navigation
    end

    # :nodoc:
    def __opal_take_pushed_events : Array(PushedEvent)
      @runtime.take_pushed_events
    end

    # :nodoc:
    def __opal_clear_pushed_events : Nil
      @runtime.clear_pushed_events
    end

    # :nodoc:
    def __opal_take_stream_operations(
      consumed_containers : Array(String)? = nil,
    ) : Array(StreamOperation)
      @runtime.take_stream_operations(consumed_containers)
    end

    # :nodoc:
    def __opal_clear_stream_operations : Nil
      @runtime.clear_stream_operations
    end
  end
end
