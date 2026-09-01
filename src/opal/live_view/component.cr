require "json"
require "../di"
require "./client_event"
require "./navigation"
require "./rendered"

module LF::LiveView
  # A connection-local, stateful piece of a LiveView.
  #
  # Components are identified by their parent, concrete type, and caller-provided
  # id. The same identity keeps the same component instance across parent renders.
  abstract class Component
    alias Factory = Proc(Component)
    alias Renderer = Proc(String, String, JSON::Any, Factory, Rendered)

    @__opal_id = ""
    @__opal_cid = 0_i64
    @__opal_connected = false
    @__opal_attached = false
    @__opal_render_component : Renderer?
    @__opal_navigate : Proc(Navigation, Nil)?
    @__opal_push_event : Proc(PushedEvent, Nil)?
    @__opal_reply : Proc(JSON::Any, Nil)?

    # Called exactly once when this component identity first appears.
    def mount : Nil
    end

    # Called before every render, including the first one.
    def update(assigns : JSON::Any) : Nil
    end

    abstract def render : RenderResult

    def handle_event(event : String, value : JSON::Any) : Nil
      raise UnknownEventError.new(event)
    end

    # The caller-provided component identity.
    def id : String
      raise Error.new("LiveView component is not attached") unless @__opal_attached
      @__opal_id
    end

    # The connection-local target used by `data-opal-target`.
    def myself : Int64
      raise Error.new("LiveView component is not attached") unless @__opal_attached
      @__opal_cid
    end

    def connected? : Bool
      @__opal_connected
    end

    protected def push_patch(to : String, *, replace : Bool = false) : Nil
      navigate(Navigation.patch(to, replace: replace))
    end

    protected def push_navigate(to : String, *, replace : Bool = false) : Nil
      navigate(Navigation.navigate(to, replace: replace))
    end

    # Renders a stateful child component. Child identities are scoped to this
    # component, so separate parent instances may reuse the same child id.
    protected def live_component(
      type : T.class,
      id : String,
      assigns : JSON::Any = JSON::Any.new(nil),
      &factory : -> T
    ) : Rendered forall T
      renderer = @__opal_render_component || raise Error.new("LiveView component is not attached")
      component_factory = -> { factory.call.as(Component) }
      renderer.call(T.name, id, assigns, component_factory)
    end

    protected def live_component(
      type : T.class,
      id : String,
      assigns,
      &factory : -> T
    ) : Rendered forall T
      live_component(type, id, JSON.parse(assigns.to_json), &factory)
    end

    protected def push_event(name : String, payload : JSON::Any = JSON::Any.new(nil)) : Nil
      callback = @__opal_push_event || raise Error.new("LiveView component is not attached")
      callback.call(PushedEvent.new(name, payload))
    end

    protected def push_event(name : String, payload) : Nil
      push_event(name, JSON.parse(payload.to_json))
    end

    protected def reply(value : JSON::Any = JSON::Any.new(nil)) : Nil
      callback = @__opal_reply || raise Error.new("LiveView component is not attached")
      callback.call(value)
    end

    protected def reply(value) : Nil
      reply(JSON.parse(value.to_json))
    end

    # :nodoc:
    def __opal_attach(
      id : String,
      cid : Int64,
      connected : Bool,
      @__opal_render_component : Renderer,
      @__opal_navigate : Proc(Navigation, Nil),
      @__opal_push_event : Proc(PushedEvent, Nil),
      @__opal_reply : Proc(JSON::Any, Nil),
    ) : Nil
      raise Error.new("LiveView component is already attached") if @__opal_attached
      @__opal_id = id
      @__opal_cid = cid
      @__opal_connected = connected
      @__opal_attached = true
    end

    # :nodoc:
    def __opal_detach : Nil
      @__opal_render_component = nil
      @__opal_navigate = nil
      @__opal_push_event = nil
      @__opal_reply = nil
    end

    # :nodoc:
    def __opal_render : Rendered
      case rendered = render
      when Rendered
        rendered
      when String
        Rendered.opaque(rendered)
      else
        raise Error.new("Unsupported LiveView component render result")
      end
    end

    private def navigate(navigation : Navigation) : Nil
      callback = @__opal_navigate || raise Error.new("LiveView component is not attached")
      callback.call(navigation)
    end
  end
end
