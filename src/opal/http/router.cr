require "http/server"
require "http/server/handlers/websocket_handler"
require "set"
require "../trie"
require "./di_integration"
require "./errors"

module LF::HTTP
  class Router
    include ::HTTP::Handler

    alias ErrorMapper = ::HTTP::Server::Context, ::HTTP::Status, String -> Nil

    @root : LF::Routing::Trie::Node
    @error_mapper : ErrorMapper
    @http_paths = Set(String).new
    @websocket_paths = Set(String).new

    def initialize(error_mapper : ErrorMapper? = nil)
      @root = LF::Routing::Trie::Node.new
      @error_mapper = error_mapper || ->(context : ::HTTP::Server::Context, status : ::HTTP::Status, body : String) do
        default_error(context, status, body)
      end
    end

    def add(path : String, methods : Set(String) = Set{"GET"}, &handler : ::HTTP::Server::Context, Hash(String, String) -> Nil)
      register_http_path(path)
      @root.add_route(path, handler, methods)
    end

    def add(path : String, handler : LF::Routing::Trie::Handler, methods : Set(String) = Set{"GET"})
      register_http_path(path)
      @root.add_route(path, handler, methods)
    end

    def ws(path : String, protocols : Array(String)? = nil, &handler : ::HTTP::WebSocket, Hash(String, String) -> Nil) : Nil
      add_websocket_route(path, protocols) do |websocket, params, _context|
        handler.call(websocket, params)
      end
    end

    # :nodoc:
    # The controller macro needs the request context for DI and request binding.
    # Crystal cannot overload these callbacks by block arity, so keep this bridge
    # separate from the public two-argument `ws` contract.
    def ws_with_context(path : String, protocols : Array(String)? = nil, &handler : ::HTTP::WebSocket, Hash(String, String), ::HTTP::Server::Context -> Nil) : Nil
      add_websocket_route(path, protocols, &handler)
    end

    private def add_websocket_route(path : String, protocols : Array(String)?, &handler : ::HTTP::WebSocket, Hash(String, String), ::HTTP::Server::Context -> Nil) : Nil
      route_key = normalize_route_path(path)
      if @http_paths.includes?(route_key) || @websocket_paths.includes?(route_key)
        raise LF::HTTP::RouteConflictError.new(path)
      end

      @websocket_paths << route_key
      @root.add_route(path, ->(context : ::HTTP::Server::Context, params : Hash(String, String)) {
        if websocket_upgrade_request?(context.request)
          websocket_handler = ::HTTP::WebSocketHandler.new(protocols) do |websocket, websocket_context|
            if registry = websocket_context.websocket_connection_registry
              io = websocket_context.websocket_io || raise "WebSocket upgrade IO is not initialized"
              websocket_context.websocket_connection = registry.register(websocket, io)
            end
            handler.call(websocket, params, websocket_context)
          end
          websocket_handler.call(context)
        else
          context.response.headers["Upgrade"] = "websocket"
          write_status(context, ::HTTP::Status::UPGRADE_REQUIRED, "Upgrade Required")
        end
      })
    end

    def get(path : String, &handler : ::HTTP::Server::Context, Hash(String, String) -> Nil)
      add(path, Set{"GET"}, &handler)
    end

    def post(path : String, &handler : ::HTTP::Server::Context, Hash(String, String) -> Nil)
      add(path, Set{"POST"}, &handler)
    end

    def put(path : String, &handler : ::HTTP::Server::Context, Hash(String, String) -> Nil)
      add(path, Set{"PUT"}, &handler)
    end

    def delete(path : String, &handler : ::HTTP::Server::Context, Hash(String, String) -> Nil)
      add(path, Set{"DELETE"}, &handler)
    end

    def patch(path : String, &handler : ::HTTP::Server::Context, Hash(String, String) -> Nil)
      add(path, Set{"PATCH"}, &handler)
    end

    def head(path : String, &handler : ::HTTP::Server::Context, Hash(String, String) -> Nil)
      add(path, Set{"HEAD"}, &handler)
    end

    def options(path : String, &handler : ::HTTP::Server::Context, Hash(String, String) -> Nil)
      add(path, Set{"OPTIONS"}, &handler)
    end

    def call(context : ::HTTP::Server::Context) : Nil
      result = @root.search(context.request.path)
      unless result.matched?
        write_status(context, ::HTTP::Status::NOT_FOUND, "Not Found")
        return
      end

      if handler = result.handler_for(context.request.method)
        handler.call(context, result.params)
      else
        context.response.headers["Allow"] = result.allowed_methods.join(", ")
        write_status(context, ::HTTP::Status::METHOD_NOT_ALLOWED, "Method Not Allowed")
      end
    end

    private def write_status(context : ::HTTP::Server::Context, status : ::HTTP::Status, body : String) : Nil
      context.response.status = status
      @error_mapper.call(context, status, body)
    end

    private def default_error(context : ::HTTP::Server::Context, status : ::HTTP::Status, body : String) : Nil
      context.response.content_type = "text/plain"
      context.response.print body
    end

    private def register_http_path(path : String) : Nil
      route_key = normalize_route_path(path)
      if @websocket_paths.includes?(route_key)
        raise LF::HTTP::RouteConflictError.new(path)
      end

      @http_paths << route_key
    end

    private def normalize_route_path(path : String) : String
      segments = path.split('/').reject(&.empty?)
      return "/" if segments.empty?

      "/" + segments.map { |segment| segment.starts_with?(':') ? ":*" : segment }.join("/")
    end

    private def websocket_upgrade_request?(request : ::HTTP::Request) : Bool
      return false unless upgrade = request.headers["Upgrade"]?
      return false unless upgrade.compare("websocket", case_insensitive: true) == 0

      request.headers.includes_word?("Connection", "Upgrade")
    end
  end
end
