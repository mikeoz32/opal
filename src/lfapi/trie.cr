
module Trie
  # Radix tree (prefix tree) implementation with URL parameter support
  #
  # Supports both exact path matching and dynamic parameters with :param_name syntax.
  # Parameters are extracted and returned in a hash for use by route handlers.
  #
  # Example:
  #   tree = Trie::Node.new
  #   tree.add_route("/users/:id", "UserHandler")
  #   tree.add_route("/posts/:post_id/comments/:comment_id", "CommentHandler")
  #
  #   result = tree.search("/users/42")
  #   result.params # => {"id" => "42"}
  #   result.node.try(&.handle) # => "UserHandler"

  # Result of a route search operation
  class MatchResult
    property node : Node?
    property params : Hash(String, String)

    def initialize(@node : Node? = nil, @params : Hash(String, String) = Hash(String, String).new)
    end
  end

  # Handler type for routes - receives context and route params
  alias Handler = Proc(HTTP::Server::Context, Hash(String, String), Nil)

  # A node in the radix tree
  # Each node represents a URL segment and can have multiple children

  class Node
    property children : Array(Node) = Array(Node).new(0)
    property path : String = ""
    property priority : Int32 = 0
    property handlers : Hash(String, Handler) = Hash(String, Handler).new
    property param_name : String = ""
    @param : Bool = false
    @exact_children : Hash(String, Node) = Hash(String, Node).new
    @param_children : Array(Node) = Array(Node).new

    def dump(indent : Int32 = 0)
      puts "#{" " * indent}#{@path} (#{@priority})"
      children.each { |child| child.dump(indent + 2) }
    end

    def param?
      @param
    end

    def param=(value : Bool)
      @param = value
    end

    protected def segments_for(path : String) : Array(String)
      path.split("/").reject(&.empty?)
    end

    protected def exact_child_for(segment : String) : Node?
      @exact_children[segment]?
    end

    protected def param_child_for(param_name : String) : Node?
      @param_children.find { |child| child.param_name == param_name }
    end

    protected def each_param_child(& : Node ->)
      @param_children.each do |child|
        yield child
      end
    end

    protected def set_handlers(methods : Set(String), handler : Handler)
      methods.each do |method|
        @handlers[method] = handler
      end
    end

    protected def attach_exact_child(child : Node)
      @children << child
      @exact_children[child.path] = child
    end

    protected def attach_param_child(child : Node)
      @children << child
      @param_children << child
    end

    def add_route(path : String, handler : Handler, methods : Set(String) = Set{"GET"})
      node = self
      @priority += 1

      # Split path into segments
      segments = segments_for(path)

      if segments.empty?
        node.set_handlers(methods, handler)
        return
      end

      segments.each_with_index do |segment, idx|
        is_last = idx == segments.size - 1

        # Check if this is a parameter segment
        if segment.starts_with?(":")
          param_name = segment[1..-1]

          # Look for existing parameter child
          param_child = node.param_child_for(param_name)

          if param_child
            node = param_child
          else
            # Create new parameter node
            child = Node.new
            child.path = segment
            child.param = true
            child.param_name = param_name
            child.priority = @priority

            node.attach_param_child(child)
            node = child
          end
        else
          # Regular segment - store without leading slash
          # Look for existing child with exact match
          existing = node.exact_child_for(segment)

          if existing
            # Exact match found, use this node
            node = existing
          else
            # Create new child
            child = Node.new
            child.path = segment
            child.priority = @priority

            node.attach_exact_child(child)
            node = child
          end
        end

        # Set handler on last segment
        if is_last
          # Add handler for each method
          node.set_handlers(methods, handler)
        end
      end
    end

    # Search for a route matching the given path
    # Returns a MatchResult containing the matched node and extracted parameters
    def search(path : String) : MatchResult
      result = MatchResult.new
      segments = segments_for(path)

      # If root node has empty path, manually match first segment with children
      if @path.empty?
        if segments.empty?
          if !@handlers.empty?
            result.node = self
            result.params = Hash(String, String).new
          end
          return result
        end

        first_segment = segments[0]

        # Try exact matches first
        if child = exact_child_for(first_segment)
          if segments.size == 1
            if !child.handlers.empty?
              result.node = child
              result.params = Hash(String, String).new
            end
            return result
          else
            child.search_segments(segments, 1, Hash(String, String).new, result)
            return result if result.node
          end
        end

        # Try parameter match
        each_param_child do |child|
          params = Hash(String, String).new
          params[child.param_name] = first_segment

          if segments.size == 1
            if !child.handlers.empty?
              result.node = child
              result.params = params
            end
            return result
          else
            child.search_segments(segments, 1, params, result)
            return result if result.node
          end
        end
      else
        search_segments(segments, 0, Hash(String, String).new, result)
      end
      result
    end

    # Internal recursive method to search through tree segments
    # Tries exact matches first, then parameter matches
    protected def search_segments(segments : Array(String), index : Int32, params : Hash(String, String), result : MatchResult)
      # Base case: all segments consumed
      if index >= segments.size
        if !@handlers.empty?
          result.node = self
          result.params = params
        end
        return
      end

      segment = segments[index]

      # Try exact match first
      if child = exact_child_for(segment)
        child.search_segments(segments, index + 1, params, result)
        return if result.node
      end

      # Try parameter match
      each_param_child do |child|
        # Extract parameter value (the current segment)
        param_value = segments[index]
        new_params = params.dup
        new_params[child.param_name] = param_value

        child.search_segments(segments, index + 1, new_params, result)
        return if result.node
      end
    end
  end
end
