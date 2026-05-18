require "http/server"
require "json"
require "fiber"
require "uuid"

require "./lfapi/di"
require "./lfapi/trie"

# Lighting FastAPI
#
# ===============================================================================
# Router System with Trie-Based Route Matching
# ===============================================================================
#
# This module provides a high-performance HTTP router built on a radix tree (Trie)
# data structure for efficient route matching with URL parameter support.
#
# Key Features:
# -------------
# - **Fast Route Matching**: O(k) complexity where k is the path length, not number of routes
# - **URL Parameters**: Dynamic path segments using :param_name syntax
# - **Multiple Parameters**: Support for multiple params per route (e.g., /api/posts/:post_id/comments/:comment_id)
# - **HTTP Method Routing**: Multiple HTTP methods (GET, POST, PUT, DELETE, PATCH) on same path
# - **Method Filtering**: Automatic 405 Method Not Allowed for wrong methods
# - **Priority Matching**: Exact paths take priority over parameter matches
#
# Architecture:
# ------------
# 1. **Trie Module**: Radix tree implementation for path matching
#    - Node: Represents a path segment in the tree
#    - MatchResult: Contains matched node and extracted parameters
#    - Handler: Proc that receives context and route parameters
#
# 2. **LF Module**: HTTP routing layer
#    - Router: Main routing class that builds and searches the Trie
#    - Convenience methods: get(), post(), put(), delete(), patch()
#    - LFApi: HTTP::Handler wrapper for easy integration
#
# Usage Example:
# -------------
#   router = LF::Router.new
#
#   router.get("/users/:id") do |ctx, params|
#     user_id = params["id"]
#     ctx.response.print "User: #{user_id}"
#   end
#
#   router.post("/api/posts/:post_id/comments/:comment_id") do |ctx, params|
#     post_id = params["post_id"]
#     comment_id = params["comment_id"]
#     ctx.response.print "Post #{post_id}, Comment #{comment_id}"
#   end
#
# ===============================================================================
#

class Hash
  def to_t(key, type)
    raise LF::BadRequest.new("Missing required parameter '#{key}'") unless self.has_key?(key)

    value = self[key]

    {% begin %}
      case type
      when Int32.class
        begin
          value.to_i
        rescue ArgumentError
          raise LF::BadRequest.new("Invalid value for parameter '#{key}': expected Int32")
        end
      when Int64.class
        begin
          value.to_i64
        rescue ArgumentError
          raise LF::BadRequest.new("Invalid value for parameter '#{key}': expected Int64")
        end
      when Float32.class
        begin
          value.to_f32
        rescue ArgumentError
          raise LF::BadRequest.new("Invalid value for parameter '#{key}': expected Float32")
        end
      when Float64.class
        begin
          value.to_f64
        rescue ArgumentError
          raise LF::BadRequest.new("Invalid value for parameter '#{key}': expected Float64")
        end
      when Bool.class
        value_str = value.to_s.downcase
        case value_str
        when "true", "1", "yes"
          true
        when "false", "0", "no"
          false
        else
          raise LF::BadRequest.new("Invalid value for parameter '#{key}': expected Bool")
        end
      when UUID.class
        begin
          UUID.new(value)
        rescue ArgumentError
          raise LF::BadRequest.new("Invalid value for parameter '#{key}': expected UUID")
        end
      when String.class
        value.to_s
      else
        raise LF::InternalServerError.new("Unsupported parameter type: #{type}")
      end
    {% end %}
  end
end

# class HTTP::Server
#   @dispatcher : Fiber::ExecutionContext::Parallel = Fiber::ExecutionContext::Parallel.new("http", 24)
#
#   protected def dispatch(io)
#     @dispatcher.spawn do
#       handle_client(io)
#     end
#   end
# end

class HTTP::Server::Context
  property state : LF::DI::AnnotationApplicationContext?
end

module LF
  # Router using Trie-based route matching with parameter support
  class Route
    include HTTP::Handler
    def initialize(@match : Trie::MatchResult)
    end

    def call(context : HTTP::Server::Context)
      if @match.node
        node = @match.node.as(Trie::Node)

        # Check if the HTTP method has a handler
        handler = node.handlers[context.request.method]?

        if handler
          # Call handler with params
          handler.call(context, @match.params)
        elsif !node.handlers.empty?
          # Path exists but method not allowed
          context.response.status = HTTP::Status::METHOD_NOT_ALLOWED
          context.response.content_type = "text/plain"
          context.response.print "Method Not Allowed"
        else
          # No handlers at all
          context.response.status = HTTP::Status::NOT_FOUND
          context.response.content_type = "text/plain"
          context.response.print "Not Found"
        end
      else
        context.response.status = HTTP::Status::NOT_FOUND
        context.response.content_type = "text/plain"
        context.response.print "Not Found"
      end
    end
  end
  class Router
    include HTTP::Handler

    @root : Trie::Node

    def initialize
      @root = Trie::Node.new
    end

    # Add a route with handler
    def add(path : String, methods : Set(String) = Set{"GET"}, &handler : HTTP::Server::Context, Hash(String, String) -> Nil)
      @root.add_route(path, handler, methods)
    end

    # Add a route with handler (non-block version)
    def add(path : String, handler : Trie::Handler, methods : Set(String) = Set{"GET"})
      @root.add_route(path, handler, methods)
    end

    # Convenience method for GET routes
    def get(path : String, &handler : HTTP::Server::Context, Hash(String, String) -> Nil)
      add(path, Set{"GET"}, &handler)
    end

    # Convenience method for POST routes
    def post(path : String, &handler : HTTP::Server::Context, Hash(String, String) -> Nil)
      add(path, Set{"POST"}, &handler)
    end

    # Convenience method for PUT routes
    def put(path : String, &handler : HTTP::Server::Context, Hash(String, String) -> Nil)
      add(path, Set{"PUT"}, &handler)
    end

    # Convenience method for DELETE routes
    def delete(path : String, &handler : HTTP::Server::Context, Hash(String, String) -> Nil)
      add(path, Set{"DELETE"}, &handler)
    end

    # Convenience method for PATCH routes
    def patch(path : String, &handler : HTTP::Server::Context, Hash(String, String) -> Nil)
      add(path, Set{"PATCH"}, &handler)
    end

    def call(context : HTTP::Server::Context)
      # @root.dump
      result = @root.search(context.request.path)

      route = Route.new(result)
      route.call(context)
    end
  end

  module Response
    abstract def call(context : HTTP::Server::Context)
  end

  module APIRoute
    annotation Route
    end

    annotation Get
    end

    annotation Post
    end

    annotation Put
    end

    annotation Delete
    end

    annotation Patch
    end

    macro __build_routes__
      def setup_routes(router : LF::Router)

      {% for method in @type.methods.sort_by(&.line_number) %}
        {% for route_method in {Get, Post, Put, Delete, Patch, Route} %}
          {% router_method = route_method.stringify.split("::")[-1].downcase.id %}
          {% router_method = "add".id if router_method == "route" %}
          {% for ann, idx in method.annotations(route_method) %}
             {% path = ann[0] || ann[:path] || raise "Missing path in #{method.name}" %}
             router.{{ router_method }}({{ path }}) do |ctx, _params|
               begin
                 {% for arg in method.args %}
                  {% if arg.name == "request" && arg.restriction.id == "HTTP::Request" %}
                    {{ arg.name }} = ctx.request
                  {% else %}
                   raise LF::InternalServerError.new("DI context not initialized") if ctx.state.nil?
                   store = ctx.state.as(LF::DI::AnnotationApplicationContext)
                   source = nil

                   if _params.has_key?("{{ arg.name }}")
                     source = _params
                   elsif (query = ctx.request.query_params) && query.has_key?("{{ arg.name }}")
                     source = query.to_h
                   elsif store.has_key?("{{ arg.name }}")
                     source = store
                   end

                   if source
                     {{ arg.name }} : {{ arg.restriction }} = source.to_t("{{ arg.name }}", {{ arg.restriction }}).as({{ arg.restriction.id }})
                   else
                     {% if parse_type(arg.restriction.stringify).resolve.ancestors.any? { |ancestor| ancestor.id == "JSON::Serializable" } %}
                       raise "Bad Request" if ctx.request.body.nil?
                       begin
                       {{ arg.name }} = {{arg.restriction.id}}.from_json(ctx.request.body.as(IO))
                       rescue e : JSON::SerializableError | JSON::ParseException
                         raise LF::BadRequest.new e.message.as(String)
                       end
                     {% else %}
                       raise LF::BadRequest.new("Missing required parameter '{{ arg.name }}'")
                     {% end %}
                   end
                  {% end %}
                 {% end %}
                 result = {{ method.name }}({% for arg in method.args %}{{ arg.name }},{% end %})
                 if result.is_a?(LF::Response)
                   result.as(LF::Response).call(ctx)
                 else
                   ctx.response.print result
                 end
               rescue e : LF::BadRequest
                 raise e
               rescue e : LF::InternalServerError
                 raise e
               rescue e : Exception
                 raise LF::InternalServerError.new("Error processing request: #{e.message}")
               end
             end
          {% end %}
        {% end %}
      {% end %}

      end
    end

    macro included
      macro finished
        __build_routes__
      end

      include HTTP::Handler

      def call(context)
        context.response.status = HTTP::Status::METHOD_NOT_ALLOWED
        context.response.content_type = "text/plain"
        context.response.print "Method Not Allowed"
      end
    end
  end

  class TextResponse
    include Response

    def initialize(content : String)
      @content = content
    end

    def self.create(content : String) : Response
      TextResponse.new(content).as(Response)
    end

    def call(context)
      context.response.content_type = "text/plain"
      context.response.print @content
    end
  end

  class HTTPException < Exception
    getter status_code : HTTP::Status

    def initialize(message : String, @status_code : HTTP::Status)
      super(message)
    end
  end

  class NotFound < HTTPException
    def initialize(message : String = "Not Found")
      super(message, HTTP::Status::NOT_FOUND)
    end
  end

  class BadRequest < HTTPException
    def initialize(message : String = "Bad Request")
      super(message, HTTP::Status::BAD_REQUEST)
    end
  end

  class InternalServerError < HTTPException
    def initialize(message : String = "Internal Server Error")
      super(message, HTTP::Status::INTERNAL_SERVER_ERROR)
    end
  end

  class JSONResponse
    include Response

    def initialize(content : JSON::Serializable)
      @content = content
    end

    def self.create(content : JSON::Serializable) : Response
      JSONResponse.new(content).as(Response)
    end

    def call(context)
      context.response.content_type = "application/json"
      @content.to_json(context.response)
    end
  end

  class LFApi
    include HTTP::Handler

    @router : Router

    def initialize(&block : Router -> Nil)
      @router = Router.new
      block.call(@router)
    end

    def initialize
      @router = Router.new
    end

    def call(context)
      @router.call(context)
    rescue e : BadRequest
      context.response.status = HTTP::Status::BAD_REQUEST
      context.response.content_type = "text/plain"
      context.response.print e.message
    rescue e : HTTPException
      context.response.status = e.status_code
      context.response.content_type = "text/plain"
      context.response.print e.message
    rescue e : Exception
      context.response.status = HTTP::Status::INTERNAL_SERVER_ERROR
      context.response.content_type = "text/plain"
      context.response.print "Internal Server Error"
    end
  end
end
