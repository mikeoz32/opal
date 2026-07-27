require "http/server"
require "../trie"

module LF::HTTP
  class Router
    include ::HTTP::Handler

    @root : LF::Routing::Trie::Node

    def initialize
      @root = LF::Routing::Trie::Node.new
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

    def call(context : ::HTTP::Server::Context) : Nil
      result = @root.search(context.request.path)
      unless result.matched?
        write_status(context, ::HTTP::Status::NOT_FOUND, "Not Found")
        return
      end

      if handler = result.handler_for(context.request.method)
        handler.call(context, result.params)
      else
        write_status(context, ::HTTP::Status::METHOD_NOT_ALLOWED, "Method Not Allowed")
      end
    end

    private def write_status(context : ::HTTP::Server::Context, status : ::HTTP::Status, body : String) : Nil
      context.response.status = status
      context.response.content_type = "text/plain"
      context.response.print body
    end
  end
end
