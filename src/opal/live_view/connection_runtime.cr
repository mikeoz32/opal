require "json"
require "log"
require "set"
require "html"
require "../di"
require "./client_event"
require "./component"
require "./error"
require "./html"
require "./navigation"
require "./rendered"
require "./stream"

module LF::LiveView
  struct Info
    getter name : String
    getter value : JSON::Any

    def initialize(@name, @value = JSON::Any.new(nil))
    end
  end

  private class ComponentTree
    ROOT_CID  = 0_i64
    MAX_DEPTH =    32

    alias Identity = Tuple(Int64, String, String)

    @components = {} of Identity => Component
    @components_by_cid = {} of Int64 => Component
    @identities_by_cid = {} of Int64 => Identity
    @children = {} of Int64 => Set(Identity)
    @rendered : Set(Identity)?
    @render_stack : Array(Int64)?
    @next_cid = 0_i64

    def initialize(
      @connected : Proc(Bool),
      @render_child_view : Component::ChildViewRenderer,
      @navigate : Proc(Navigation, Nil),
      @push_event : Proc(PushedEvent, Nil),
      @reply : Proc(JSON::Any, Nil),
    )
    end

    def render(& : -> Rendered) : Rendered
      existing = @components.keys.to_set
      begin
        if @rendered || @render_stack
          raise Error.new("LiveView render callbacks cannot be nested")
        end

        rendered = Set(Identity).new
        @rendered = rendered
        @render_stack = [ROOT_CID]
        result = yield

        stale = @components.keys.reject { |identity| rendered.includes?(identity) }
        stale.each { |identity| destroy_tree(identity) }
        result
      rescue error
        created = @components.keys.reject { |identity| existing.includes?(identity) }
        created.each { |identity| destroy_tree(identity) }
        raise error
      ensure
        @rendered = nil
        @render_stack = nil
      end
    end

    def render_root(
      type_name : String,
      id : String,
      assigns : JSON::Any,
      factory : Component::Factory,
    ) : Rendered
      render_component(ROOT_CID, type_name, id, assigns, factory)
    end

    def handle_event(cid : Int64, event : String, value : JSON::Any) : Nil
      component = @components_by_cid[cid]? || raise UnknownComponentError.new
      component.handle_event(event, value)
    end

    def disconnect : Nil
      @rendered = nil
      @render_stack = nil
      roots = @children[ROOT_CID]?.try(&.to_a) || [] of Identity
      roots.each { |identity| destroy_tree(identity) }
      @components.keys.each { |identity| destroy_tree(identity) }
      @components_by_cid.clear
      @identities_by_cid.clear
      @children.clear
    end

    private def render_component(
      parent_cid : Int64,
      type_name : String,
      id : String,
      assigns : JSON::Any,
      factory : Component::Factory,
    ) : Rendered
      rendered = @rendered
      render_stack = @render_stack
      unless rendered && render_stack && render_stack.last? == parent_cid
        raise Error.new("LiveView components can only be rendered from their active parent render")
      end

      if render_stack.size - 1 >= MAX_DEPTH
        raise ComponentNestingError.new(MAX_DEPTH)
      end

      render_stack.skip(1).each do |ancestor_cid|
        next unless ancestor = @identities_by_cid[ancestor_cid]?
        if ancestor[1] == type_name && ancestor[2] == id
          raise RecursiveComponentError.new(type_name, id)
        end
      end

      identity = {parent_cid, type_name, id}
      if rendered.includes?(identity)
        raise DuplicateComponentError.new(type_name)
      end

      component = @components[identity]? || create_component(identity, factory.call)
      rendered << identity
      render_stack << component.myself
      begin
        component.update(assigns)
        Rendered.component(
          ComponentContent.new(component.myself, component.__opal_render, "opal-live-root")
        )
      ensure
        render_stack.pop
      end
    end

    private def create_component(identity : Identity, component : Component) : Component
      @next_cid += 1
      component_cid = @next_cid
      render_child = ->(type_name : String, id : String, assigns : JSON::Any, factory : Component::Factory) do
        render_component(component_cid, type_name, id, assigns, factory)
      end
      component.__opal_attach(
        identity[2],
        component_cid,
        @connected.call,
        render_child,
        @render_child_view,
        @navigate,
        @push_event,
        @reply
      )
      begin
        component.mount
      rescue error
        destroy_component(component)
        raise error
      end

      @components[identity] = component
      @components_by_cid[component_cid] = component
      @identities_by_cid[component_cid] = identity
      children = @children[identity[0]] ||= Set(Identity).new
      children << identity
      component
    end

    private def destroy_tree(identity : Identity) : Nil
      component = @components[identity]?
      return unless component

      component_cid = component.myself
      children = @children.delete(component_cid).try(&.to_a) || [] of Identity
      children.each { |child| destroy_tree(child) }
      @components.delete(identity)
      @components_by_cid.delete(component_cid)
      @identities_by_cid.delete(component_cid)
      if siblings = @children[identity[0]]?
        siblings.delete(identity)
        @children.delete(identity[0]) if siblings.empty?
      end
      destroy_component(component)
    end

    private def destroy_component(component : Component) : Nil
      component.__opal_detach
      if disposable = component.as?(LF::DI::Disposable)
        disposable.destroy
      end
    rescue error : Exception
      Log.error(exception: error) do
        "LiveView component cleanup failed: component=#{component.class.name}"
      end
    end
  end

  private class StreamState
    @operations = [] of StreamOperation
    @items = {} of String => Array(Tuple(String, String))
    @committed_items = {} of String => Array(Tuple(String, String))
    @references = {} of String => String
    @next_reference = 0

    def insert(
      container_id : String,
      item_id : String,
      html : String,
      at : Int32,
      limit : Int32?,
      update_only : Bool,
    ) : Nil
      validate_id(container_id, "container")
      validate_id(item_id, "item")
      validate_item_html(item_id, html)
      raise ArgumentError.new("LiveView stream insertion index must be -1 or greater") if at < -1
      if limit.try(&.zero?)
        raise ArgumentError.new("LiveView stream limit cannot be zero")
      end

      items = @items[container_id] ||= [] of Tuple(String, String)
      changed = false
      if index = items.index { |item| item[0] == item_id }
        items[index] = {item_id, html}
        changed = true
      elsif !update_only
        index = at == -1 || at >= items.size ? items.size : at
        items.insert(index, {item_id, html})
        changed = true
      end
      apply_limit(items, limit) if changed
      @operations << StreamOperation.insert(container_id, item_id, html, at, limit, update_only)
    end

    def delete(container_id : String, item_id : String) : Nil
      validate_id(container_id, "container")
      validate_id(item_id, "item")
      @items[container_id]?.try(&.reject! { |item| item[0] == item_id })
      @operations << StreamOperation.delete(container_id, item_id)
    end

    def reset(container_id : String) : Nil
      validate_id(container_id, "container")
      @items[container_id] = [] of Tuple(String, String)
      @operations.reject! { |operation| operation.container_id == container_id }
      @operations << StreamOperation.reset(container_id)
    end

    def contents(container_id : String) : StreamContent
      validate_id(container_id, "container")
      items = @items[container_id]? || [] of Tuple(String, String)
      html = String.build do |output|
        items.each { |item| output << item[1] }
      end
      inserts, delete_ids, reset = native_operations(container_id)
      StreamContent.new(
        container_id,
        reference_for(container_id),
        html,
        inserts,
        delete_ids,
        reset
      )
    end

    def take(consumed_containers : Array(String)? = nil) : Array(StreamOperation)
      validate_consumed!(consumed_containers) if consumed_containers
      operations = @operations
      @operations = [] of StreamOperation
      @committed_items = duplicate_items(@items)
      operations
    end

    def clear : Nil
      @operations.clear
      @items.clear
      @committed_items.clear
      @references.clear
      @next_reference = 0
    end

    def clear_operations : Nil
      @operations.clear
      @items = duplicate_items(@committed_items)
    end

    private def validate_id(id : String, kind : String) : Nil
      if id.empty?
        raise ArgumentError.new("LiveView stream #{kind} id cannot be empty")
      end
    end

    private def validate_item_html(item_id : String, html : String) : Nil
      root = html.match(
        /\A\s*(?:<!--(?s:.*?)-->\s*)*<[A-Za-z][A-Za-z0-9:-]*(?:\s+(?:[^"'<>]|"[^"]*"|'[^']*')*)?\s*\/?>/
      )
      unless root
        raise ArgumentError.new("LiveView stream item '#{item_id}' must render one root HTML element")
      end
      id = root[0].match(/\sid\s*=\s*(?:"([^"]*)"|'([^']*)')/)
      rendered_id = id.try { |match| match[1]? || match[2]? }
      unless rendered_id && ::HTML.unescape(rendered_id) == item_id
        raise ArgumentError.new(
          "LiveView stream item '#{item_id}' root id must match its stream id"
        )
      end
    end

    private def reference_for(container_id : String) : String
      @references[container_id] ||= begin
        reference = @next_reference.to_s
        @next_reference += 1
        reference
      end
    end

    private def native_operations(
      container_id : String,
    ) : {Array(StreamInsert), Array(String), Bool}
      operations = @operations.select { |operation| operation.container_id == container_id }
      reset = operations.any? { |operation| operation.operation == "reset" }
      committed_ids = Set(String).new(
        (@committed_items[container_id]? || [] of Tuple(String, String)).map(&.[0])
      )
      inserts = [] of StreamInsert
      delete_ids = [] of String

      operations.each do |operation|
        item_id = operation.item_id
        case operation.operation
        when "insert"
          id = item_id.not_nil!
          inserts.reject! { |insert| insert.item_id == id }
          if !committed_ids.includes?(id)
            delete_ids.delete(id)
          end
          inserts << StreamInsert.new(
            id,
            operation.html.not_nil!,
            operation.at.not_nil!,
            operation.limit,
            operation.update_only?
          )
        when "delete"
          id = item_id.not_nil!
          inserts.reject! { |insert| insert.item_id == id }
          delete_ids << id unless reset || delete_ids.includes?(id)
        end
      end

      {inserts, delete_ids, reset}
    end

    private def validate_consumed!(consumed_containers : Array(String)) : Nil
      duplicates = consumed_containers.group_by(&.itself).find { |_container, values| values.size > 1 }
      if duplicate = duplicates
        raise Error.new("LiveView stream '#{duplicate[0]}' was rendered more than once")
      end

      pending = @operations.map(&.container_id).uniq
      if missing = pending.find { |container_id| !consumed_containers.includes?(container_id) }
        raise Error.new("LiveView stream '#{missing}' has pending operations but was not rendered")
      end
    end

    private def apply_limit(items : Array(Tuple(String, String)), limit : Int32?) : Nil
      return unless limit
      if limit > 0
        while items.size > limit
          items.pop
        end
      else
        keep = -limit.to_i64
        while items.size > keep
          items.shift
        end
      end
    end

    private def duplicate_items(
      source : Hash(String, Array(Tuple(String, String))),
    ) : Hash(String, Array(Tuple(String, String)))
      source.transform_values(&.dup)
    end
  end

  private class NavigationState
    @navigation : Navigation?

    def queue(navigation : Navigation) : Nil
      if @navigation
        raise DuplicateNavigationError.new
      end
      @navigation = navigation
    end

    def take : Navigation?
      navigation = @navigation
      @navigation = nil
      navigation
    end

    def clear : Nil
      @navigation = nil
    end
  end

  private class ClientEventState
    @pushed = [] of PushedEvent
    @reply : EventReply?
    @handling = false

    def handle(& : -> Nil) : EventReply?
      raise Error.new("LiveView event callbacks cannot be nested") if @handling
      @handling = true
      @reply = nil
      result : EventReply? = nil
      begin
        yield
        result = @reply
      ensure
        @reply = nil
        @handling = false
      end
      result
    end

    def push(event : PushedEvent) : Nil
      raise ArgumentError.new("LiveView pushed event name cannot be empty") if event.name.empty?
      @pushed << event
    end

    def reply(value : JSON::Any) : Nil
      unless @handling
        raise EventReplyError.new("LiveView replies are only valid inside an event callback")
      end
      if @reply
        raise EventReplyError.new("A LiveView event callback can reply only once")
      end
      @reply = EventReply.new(value)
    end

    def take_pushed : Array(PushedEvent)
      events = @pushed
      @pushed = [] of PushedEvent
      events
    end

    def clear_pushed : Nil
      @pushed.clear
    end

    def clear : Nil
      @pushed.clear
      @reply = nil
      @handling = false
    end
  end

  # Owns all mutable infrastructure state for one disconnected render or
  # connected LiveView session. Application views remain lifecycle callbacks
  # and delegate connection concerns through this runtime.
  # :nodoc:
  class ConnectionRuntime
    ROOT_COMPONENT_CID  = ComponentTree::ROOT_CID
    MAX_COMPONENT_DEPTH = ComponentTree::MAX_DEPTH

    alias ChildViewRenderer = Proc(String, String, JSON::Any, ChildViewFactory, ChildViewContent)

    @send_info : Proc(Info, Bool)?
    @refresh : Proc(Bool)?
    @connected = false
    @components : ComponentTree
    @streams = StreamState.new
    @navigation = NavigationState.new
    @events = ClientEventState.new
    @render_child_view : ChildViewRenderer?
    @finish_child_views : Proc(Set(String), Nil)?
    @rendered_child_ids : Set(String)?

    def initialize
      connected = -> { @connected }
      navigate = ->(navigation : Navigation) { @navigation.queue(navigation) }
      push_event = ->(event : PushedEvent) { @events.push(event) }
      reply = ->(value : JSON::Any) { @events.reply(value) }
      render_child_view = ->(type_name : String, id : String, session : JSON::Any, factory : ChildViewFactory) { render_child_view(type_name, id, session, factory) }
      @components = ComponentTree.new(connected, render_child_view, navigate, push_event, reply)
    end

    def prepare_mount(connected : Bool) : Nil
      @connected = connected
    end

    def connect(
      @send_info : Proc(Info, Bool),
      @refresh : Proc(Bool),
    ) : Nil
    end

    def disconnect : Nil
      @send_info = nil
      @refresh = nil
      @components.disconnect
      @streams.clear
      @navigation.clear
      @events.clear
      @render_child_view = nil
      @finish_child_views = nil
      @rendered_child_ids = nil
    end

    def send_info(info : Info) : Bool
      @send_info.try(&.call(info)) || false
    end

    def refresh : Bool
      @refresh.try(&.call) || false
    end

    def navigate(navigation : Navigation) : Nil
      @navigation.queue(navigation)
    end

    def push_event(event : PushedEvent) : Nil
      @events.push(event)
    end

    def reply(value : JSON::Any) : Nil
      @events.reply(value)
    end

    def render_component(
      type_name : String,
      id : String,
      assigns : JSON::Any,
      factory : Component::Factory,
    ) : Rendered
      @components.render_root(type_name, id, assigns, factory)
    end

    def configure_child_views(
      @render_child_view : ChildViewRenderer,
      @finish_child_views : Proc(Set(String), Nil),
    ) : Nil
    end

    def render_child_view(
      type_name : String,
      id : String,
      session : JSON::Any,
      factory : ChildViewFactory,
    ) : ChildViewContent
      rendered = @rendered_child_ids || raise Error.new(
        "Child LiveViews can only be rendered from an active LiveView render"
      )
      if id.empty?
        raise ArgumentError.new("Child LiveView id cannot be empty")
      end
      unless rendered.add?(id)
        raise DuplicateChildViewError.new(id)
      end
      renderer = @render_child_view || raise Error.new("Child LiveView rendering is not configured")
      renderer.call(type_name, id, session, factory)
    end

    def stream_insert(
      container_id : String,
      item_id : String,
      rendered : RenderResult,
      *,
      at : Int32 = -1,
      limit : Int32? = nil,
      update_only : Bool = false,
    ) : Nil
      @streams.insert(
        container_id,
        item_id,
        normalize_render(rendered).to_html,
        at,
        limit,
        update_only
      )
    end

    def stream_delete(container_id : String, item_id : String) : Nil
      @streams.delete(container_id, item_id)
    end

    def stream_reset(container_id : String) : Nil
      @streams.reset(container_id)
    end

    def stream_contents(container_id : String) : StreamContent
      @streams.contents(container_id)
    end

    def render(& : -> RenderResult) : Rendered
      if @rendered_child_ids
        raise Error.new("LiveView render callbacks cannot be nested")
      end
      child_ids = Set(String).new
      @rendered_child_ids = child_ids
      result = @components.render { normalize_render(yield) }
      @finish_child_views.try(&.call(child_ids))
      result
    ensure
      @rendered_child_ids = nil
    end

    def handle_event(
      target : Int64?,
      event : String,
      value : JSON::Any,
      &view_handler : -> Nil
    ) : EventReply?
      @events.handle do
        if cid = target
          @components.handle_event(cid, event, value)
        else
          view_handler.call
        end
      end
    end

    def take_navigation : Navigation?
      @navigation.take
    end

    def clear_navigation : Nil
      @navigation.clear
    end

    def take_pushed_events : Array(PushedEvent)
      @events.take_pushed
    end

    def clear_pushed_events : Nil
      @events.clear_pushed
    end

    def take_stream_operations(
      consumed_containers : Array(String)? = nil,
    ) : Array(StreamOperation)
      @streams.take(consumed_containers)
    end

    def clear_stream_operations : Nil
      @streams.clear_operations
    end

    private def normalize_render(rendered : RenderResult) : Rendered
      case rendered
      when Rendered
        rendered
      when String
        Rendered.opaque(rendered)
      else
        raise Error.new("Unsupported LiveView render result")
      end
    end
  end
end
