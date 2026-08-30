require "http/request"
require "json"
require "uri"
require "./html"

module LF::LiveView
  annotation Page
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
    @refresh : Proc(Nil)?

    def mount(context : MountContext) : Nil
    end

    abstract def render : String

    def handle_event(event : String, value : JSON::Any) : Nil
      raise UnknownEventError.new(event)
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

    # Schedules one coalesced render for state changed outside `handle_event`,
    # for example by a subscription or timer. Events rerender automatically.
    protected def refresh : Nil
      @refresh.try(&.call)
    end

    # :nodoc:
    def __opal_connect(&refresh : -> Nil) : Nil
      @refresh = refresh
    end

    # :nodoc:
    def __opal_disconnect : Nil
      @refresh = nil
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

  class InvalidMountTokenError < Error
    def initialize
      super("Invalid LiveView mount token")
    end
  end

  class ProtocolError < Error
  end
end
