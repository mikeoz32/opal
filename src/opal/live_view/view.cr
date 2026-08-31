require "http/request"
require "json"
require "log"
require "set"
require "uri"
require "./component"
require "./html"
require "./navigation"
require "./rendered"
require "./stream"

module LF::LiveView
  annotation Page
  end

  struct Info
    getter name : String
    getter value : JSON::Any

    def initialize(@name, @value = JSON::Any.new(nil))
    end
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

    def initialize(@request, params : Hash(String, String), resource : String, @connected)
      super(params, resource)
    end
  end

  abstract class View
    alias ComponentIdentity = Tuple(String, String)

    @send_info : Proc(Info, Bool)?
    @refresh : Proc(Bool)?
    @components = {} of ComponentIdentity => Component
    @components_by_cid = {} of Int64 => Component
    @rendered_components : Set(ComponentIdentity)?
    @next_component_cid = 0_i64
    @connected = false
    @stream_operations = [] of StreamOperation
    @navigation : Navigation?

    def mount(context : MountContext) : Nil
    end

    # Runs after mount and whenever a live patch changes the current route or
    # query parameters without replacing this view instance.
    def handle_params(context : ParamsContext) : Nil
    end

    abstract def render : RenderResult

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
      dispatcher = @send_info
      return false unless dispatcher
      dispatcher.call(Info.new(name, value))
    end

    # Schedules one coalesced render when state was changed by code already
    # running on the LiveView connection fiber.
    protected def refresh : Bool
      @refresh.try(&.call) || false
    end

    # Changes the URL inside this LiveView without remounting it.
    protected def push_patch(to : String, *, replace : Bool = false) : Nil
      queue_navigation(Navigation.patch(to, replace: replace))
    end

    # Navigates through a fresh HTTP mount. Opal does not yet define
    # cross-view live sessions, so this intentionally replaces the document.
    protected def push_navigate(to : String, *, replace : Bool = false) : Nil
      queue_navigation(Navigation.navigate(to, replace: replace))
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
      rendered_components = @rendered_components
      raise Error.new("LiveView components can only be rendered from View#render") unless rendered_components

      identity = {T.name, id}
      if rendered_components.includes?(identity)
        raise DuplicateComponentError.new(T.name)
      end

      component = if existing = @components[identity]?
                    existing.as(T)
                  else
                    create_component(identity, factory.call)
                  end

      rendered_components << identity
      component.update(assigns)
      component.__opal_render
    end

    protected def live_component(
      type : T.class,
      id : String,
      assigns,
      &factory : -> T
    ) : Rendered forall T
      live_component(type, id, JSON.parse(assigns.to_json), &factory)
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
    ) : Nil
      validate_stream_id(container_id, "container")
      validate_stream_id(item_id, "item")
      raise ArgumentError.new("LiveView stream insertion index must be -1 or greater") if at < -1
      if limit.try(&.zero?)
        raise ArgumentError.new("LiveView stream limit cannot be zero")
      end

      html = normalize_render(rendered).to_html
      @stream_operations << StreamOperation.insert(container_id, item_id, html, at, limit)
    end

    # Queues removal of one direct child from a browser-owned stream container.
    protected def stream_delete(container_id : String, item_id : String) : Nil
      validate_stream_id(container_id, "container")
      validate_stream_id(item_id, "item")
      @stream_operations << StreamOperation.delete(container_id, item_id)
    end

    # Queues removal of every child in a browser-owned stream container.
    protected def stream_reset(container_id : String) : Nil
      validate_stream_id(container_id, "container")
      @stream_operations << StreamOperation.reset(container_id)
    end

    # Renders the currently queued contents for the disconnected HTTP response.
    # The same operations are later sent to a protocol-v2 client. Stream item
    # markup is already trusted framework output and is not escaped again.
    protected def stream_contents(container_id : String) : HTML::Safe
      validate_stream_id(container_id, "container")
      items = [] of Tuple(String, String)

      @stream_operations.each do |operation|
        next unless operation.container_id == container_id
        case operation.operation
        when "reset"
          items.clear
        when "delete"
          item_id = operation.item_id.not_nil!
          items.reject! { |item| item[0] == item_id }
        when "insert"
          item_id = operation.item_id.not_nil!
          html = operation.html.not_nil!
          if index = items.index { |item| item[0] == item_id }
            items[index] = {item_id, html}
          else
            at = operation.at.not_nil!
            index = at == -1 || at >= items.size ? items.size : at
            items.insert(index, {item_id, html})
          end
          apply_stream_limit(items, operation.limit)
        end
      end

      HTML.raw(String.build do |output|
        items.each { |item| output << item[1] }
      end)
    end

    # :nodoc:
    def __opal_mount(context : MountContext) : Nil
      @connected = context.connected?
      mount(context)
    end

    # :nodoc:
    def __opal_connect(
      @send_info : Proc(Info, Bool),
      @refresh : Proc(Bool),
    ) : Nil
    end

    # :nodoc:
    def __opal_disconnect : Nil
      @send_info = nil
      @refresh = nil
      components = @components.values
      @components.clear
      @components_by_cid.clear
      @rendered_components = nil
      @stream_operations.clear
      @navigation = nil
      components.each { |component| destroy_component(component) }
    end

    # :nodoc:
    def __opal_render : Rendered
      rendered_components = Set(ComponentIdentity).new
      @rendered_components = rendered_components
      rendered = normalize_render(render)

      stale = @components.keys.reject { |identity| rendered_components.includes?(identity) }
      stale.each do |identity|
        if component = @components.delete(identity)
          @components_by_cid.delete(component.myself)
          destroy_component(component)
        end
      end
      rendered
    ensure
      @rendered_components = nil
    end

    # :nodoc:
    def __opal_handle_event(target : Int64?, event : String, value : JSON::Any) : Nil
      if cid = target
        component = @components_by_cid[cid]? || raise UnknownComponentError.new
        component.handle_event(event, value)
      else
        handle_event(event, value)
      end
    end

    # :nodoc:
    def __opal_handle_params(context : ParamsContext) : Nil
      handle_params(context)
    end

    # :nodoc:
    def __opal_take_navigation : Navigation?
      navigation = @navigation
      @navigation = nil
      navigation
    end

    # :nodoc:
    def __opal_clear_navigation : Nil
      @navigation = nil
    end

    # :nodoc:
    def __opal_take_stream_operations : Array(StreamOperation)
      operations = @stream_operations
      @stream_operations = [] of StreamOperation
      operations
    end

    # :nodoc:
    def __opal_clear_stream_operations : Nil
      @stream_operations.clear
    end

    private def normalize_render(rendered : RenderResult) : Rendered
      case rendered
      when Rendered
        rendered
      when String
        Rendered.opaque(rendered)
      else
        raise Error.new("Unsupported LiveView render result")
      end
    end

    private def queue_navigation(navigation : Navigation) : Nil
      if @navigation
        raise DuplicateNavigationError.new
      end
      @navigation = navigation
    end

    private def create_component(identity : ComponentIdentity, component : T) : T forall T
      @next_component_cid += 1
      navigate = ->(navigation : Navigation) { queue_navigation(navigation) }
      component.__opal_attach(identity[1], @next_component_cid, @connected, navigate)
      begin
        component.mount
      rescue error
        destroy_component(component)
        raise error
      end
      @components[identity] = component
      @components_by_cid[component.myself] = component
      component
    end

    private def destroy_component(component : Component) : Nil
      component.__opal_detach
      component.as?(LF::DI::Disposable).try(&.destroy)
    rescue error : Exception
      Log.error(exception: error) do
        "LiveView component cleanup failed: component=#{component.class.name}"
      end
    end

    private def validate_stream_id(id : String, kind : String) : Nil
      if id.empty?
        raise ArgumentError.new("LiveView stream #{kind} id cannot be empty")
      end
    end

    private def apply_stream_limit(items : Array(Tuple(String, String)), limit : Int32?) : Nil
      return unless limit
      if limit > 0
        while items.size > limit
          items.pop
        end
      else
        keep = -limit.to_i64
        while items.size > keep
          items.shift
        end
      end
    end
  end

  class Error < Exception
  end

  class ConfigurationError < Error
  end

  class UnknownEventError < Error
    getter event : String

    def initialize(@event)
      super("Unknown LiveView event: #{event}")
    end
  end

  class UnknownInfoError < Error
    getter info : String

    def initialize(@info)
      super("Unknown LiveView info: #{info}")
    end
  end

  class UnknownComponentError < Error
    def initialize
      super("Unknown LiveView component target")
    end
  end

  class DuplicateComponentError < Error
    def initialize(type : String)
      super("Duplicate LiveView component identity for #{type}")
    end
  end

  class DuplicateNavigationError < Error
    def initialize
      super("A LiveView callback can request only one navigation")
    end
  end

  class InvalidNavigationError < Error
    def initialize
      super("Invalid LiveView navigation")
    end
  end

  class InvalidMountTokenError < Error
    def initialize
      super("Invalid LiveView mount token")
    end
  end

  class ProtocolError < Error
  end
end
