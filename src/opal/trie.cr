require "http/server"

module LF::Routing::Trie
  alias Handler = Proc(::HTTP::Server::Context, Hash(String, String), Nil)

  class MatchResult
    getter params : Hash(String, String)

    def initialize(@node : Node? = nil, @params = Hash(String, String).new)
    end

    def matched? : Bool
      !@node.nil?
    end

    def handler_for(method : String) : Handler?
      @node.try(&.handler_for(method))
    end

    def allowed_methods : Array(String)
      @node.try(&.allowed_methods) || [] of String
    end

    # :nodoc:
    def record(node : Node, params : Hash(String, String)) : Nil
      @node = node
      @params = params
    end
  end

  class Node
    @path = ""
    @param_name = ""
    @handlers = Hash(String, Handler).new
    @exact_children = Hash(String, Node).new
    @param_children = Array(Node).new

    protected getter path
    protected getter param_name

    def add_route(path : String, handler : Handler, methods : Set(String) = Set{"GET"}) : Nil
      node = self
      segments = segments_for(path)

      if segments.empty?
        node.set_handlers(methods, handler)
        return
      end

      segments.each do |segment|
        node = if segment.starts_with?(':')
                 node.param_child(segment[1..])
               else
                 node.exact_child(segment)
               end
      end

      node.set_handlers(methods, handler)
    end

    def search(path : String) : MatchResult
      segments = segments_for(path)
      return MatchResult.new(self) if segments.empty? && !@handlers.empty?

      result = MatchResult.new
      search_segments(segments, 0, Hash(String, String).new, result)
      result
    end

    def handler_for(method : String) : Handler?
      @handlers[method]?
    end

    def allowed_methods : Array(String)
      @handlers.keys.sort
    end

    private def segments_for(path : String) : Array(String)
      path.split('/').reject(&.empty?)
    end

    protected def exact_child(segment : String) : Node
      @exact_children[segment]? || begin
        child = Node.new
        child.set_path(segment)
        @exact_children[segment] = child
      end
    end

    protected def param_child(name : String) : Node
      @param_children.find { |child| child.param_name == name } || begin
        child = Node.new
        child.set_path(":#{name}")
        child.set_param_name(name)
        @param_children << child
        child
      end
    end

    protected def set_path(path : String) : Nil
      @path = path
    end

    protected def set_param_name(name : String) : Nil
      @param_name = name
    end

    protected def set_handlers(methods : Set(String), handler : Handler) : Nil
      methods.each { |method| @handlers[method] = handler }
    end

    protected def search_segments(
      segments : Array(String),
      index : Int32,
      params : Hash(String, String),
      result : MatchResult,
    ) : Nil
      if index >= segments.size
        result.record(self, params) unless @handlers.empty?
        return
      end

      segment = segments[index]

      if child = @exact_children[segment]?
        child.search_segments(segments, index + 1, params, result)
        return if result.matched?
      end

      @param_children.each do |child|
        next_params = params.dup
        next_params[child.param_name] = segment
        child.search_segments(segments, index + 1, next_params, result)
        return if result.matched?
      end
    end
  end
end
