require "http/server"
require "../trie"

module LF::HTTP
  class Router
    include ::HTTP::Handler

    alias ErrorMapper = ::HTTP::Server::Context, ::HTTP::Status, String -> Nil

    @root : LF::Routing::Trie::Node
    @error_mapper : ErrorMapper

    def initialize(error_mapper : ErrorMapper? = nil)
      @root = LF::Routing::Trie::Node.new
      @error_mapper = error_mapper || ->(context : ::HTTP::Server::Context, status : ::HTTP::Status, body : String) do
        default_error(context, status, body)
      end
    end

    def add(path : String, methods : Set(String) = Set{"GET"}, &handler : ::HTTP::Server::Context, Hash(String, String) -> Nil)
      @root.add_route(path, handler, methods)
    end

    def add(path : String, handler : LF::Routing::Trie::Handler, methods : Set(String) = Set{"GET"})
      @root.add_route(path, handler, methods)
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
  end
end
