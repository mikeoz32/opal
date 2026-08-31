require "json"
require "../di"
require "./rendered"

module LF::LiveView
  # A connection-local, stateful piece of a LiveView.
  #
  # Components are identified by their concrete type and caller-provided id.
  # The same identity keeps the same component instance across parent renders.
  abstract class Component
    @__opal_id = ""
    @__opal_cid = 0_i64
    @__opal_connected = false
    @__opal_attached = false

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

    # :nodoc:
    def __opal_attach(id : String, cid : Int64, connected : Bool) : Nil
      raise Error.new("LiveView component is already attached") if @__opal_attached
      @__opal_id = id
      @__opal_cid = cid
      @__opal_connected = connected
      @__opal_attached = true
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
  end
end
