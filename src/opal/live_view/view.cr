require "http/request"
require "json"
require "log"
require "set"
require "uri"
require "./component"
require "./html"
require "./rendered"

module LF::LiveView
  annotation Page
  end

  struct Info
    getter name : String
    getter value : JSON::Any

    def initialize(@name, @value = JSON::Any.new(nil))
    end
  end

  class MountContext
    getter request : ::HTTP::Request
    getter params : Hash(String, String)
    getter uri : URI
    getter? connected : Bool

    def initialize(@request, @params, resource : String, @connected)
      @uri = URI.parse(resource)
    end

    def query_params : URI::Params
      @uri.query_params
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

    def mount(context : MountContext) : Nil
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

    private def create_component(identity : ComponentIdentity, component : T) : T forall T
      @next_component_cid += 1
      component.__opal_attach(identity[1], @next_component_cid, @connected)
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
      component.as?(LF::DI::Disposable).try(&.destroy)
    rescue error : Exception
      Log.error(exception: error) do
        "LiveView component cleanup failed: component=#{component.class.name}"
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

  class InvalidMountTokenError < Error
    def initialize
      super("Invalid LiveView mount token")
    end
  end

  class ProtocolError < Error
  end
end
