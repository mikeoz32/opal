require "http/request"
require "json"
require "uri"
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
    @send_info : Proc(Info, Bool)?
    @refresh : Proc(Bool)?

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
    end

    # :nodoc:
    def __opal_render : Rendered
      case rendered = render
      when Rendered
        rendered
      when String
        Rendered.opaque(rendered)
      else
        raise Error.new("Unsupported LiveView render result")
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

  class InvalidMountTokenError < Error
    def initialize
      super("Invalid LiveView mount token")
    end
  end

  class ProtocolError < Error
  end
end
