require "http/web_socket"
require "json"
require "log"
require "uri"
require "../di"
require "../http/execution_pipeline"
require "../http/router"
require "./error"
require "./html"
require "./mount_token"
require "./view"

module LF::LiveView
  class Endpoint
    LIVE_VIEW_VERSION    = "1.2.11"
    SOCKET_PATH          = "/_opal/live"
    CLIENT_PATH          = "/_opal/live.js"
    MAX_CHILD_VIEW_DEPTH = 32
    CLIENT_SOURCE        = {{ read_file("#{__DIR__}/../../../assets/opal_live_view.js") }}

    private class Route
      getter name : String
      getter path : String
      getter? managed_by_scope : Bool

      def initialize(
        @name,
        @path,
        @managed_by_scope,
        @factory : Proc(LF::DI::Container, View),
        @guards : Proc(LF::DI::Container, Array(LF::HTTP::Guard)),
      )
      end

      def build(scope : LF::DI::Container) : View
        @factory.call(scope)
      end

      def guards(scope : LF::DI::Container) : Array(LF::HTTP::Guard)
        @guards.call(scope)
      end

      def match_path(path : String) : Hash(String, String)?
        pattern_segments = segments(@path)
        path_segments = segments(path)
        return nil unless pattern_segments.size == path_segments.size

        params = {} of String => String
        pattern_segments.each_with_index do |segment, index|
          value = path_segments[index]
          if segment.starts_with?(':')
            params[segment[1..]] = value
          elsif segment != value
            return nil
          end
        end
        params
      end

      private def segments(path : String) : Array(String)
        path.split('/').reject(&.empty?)
      end
    end

    private struct NavigationResult
      getter navigation : Navigation
      getter token : String?

      def initialize(@navigation, @token = nil)
      end
    end

    private struct ChannelMessage
      getter join_ref : String?
      getter reference : String?
      getter topic : String
      getter event : String
      getter payload : JSON::Any

      def initialize(@join_ref, @reference, @topic, @event, @payload)
      end
    end

    private struct ChannelUpdate
      getter topic : String
      getter info : Info?

      def initialize(@topic, @info = nil)
      end
    end

    private class ChannelFailure < Exception
      getter close_reason : String

      def initialize(@close_reason)
        super(@close_reason)
      end
    end

    private class ChildRegistration
      getter type_name : String
      getter id : String
      getter parent_id : String
      getter parent_topic : String
      getter session : JSON::Any
      getter resource : String
      getter depth : Int32
      getter factory : ChildViewFactory

      def initialize(
        @type_name,
        @id,
        @parent_id,
        @parent_topic,
        @session,
        @resource,
        @depth,
        @factory,
      )
      end
    end

    private class ConnectedChannel
      getter join : ChannelMessage
      getter route : Route
      getter view : View
      getter type_name : String
      getter view_id : String
      getter parent_topic : String?
      getter resource : String
      getter depth : Int32
      property rendered : Rendered?

      def initialize(
        @join,
        @route,
        @view,
        @type_name,
        @view_id,
        @parent_topic,
        @resource,
        @depth,
        @rendered = nil,
      )
      end

      def root? : Bool
        @parent_topic.nil?
      end
    end

    getter socket_path : String
    getter client_path : String

    @routes = {} of String => Route
    @paths = Set(String).new
    @allowed_origins : Array(String)
    @mounted = false

    def initialize(
      secret : String,
      @socket_path = SOCKET_PATH,
      @client_path = CLIENT_PATH,
      allowed_origins = [] of String,
      mount_token_max_age = 24.hours,
      @max_message_bytes = 64 * 1024,
      @join_timeout = 10.seconds,
      @idle_timeout = 75.seconds,
    )
      @tokens = MountToken.new(secret, mount_token_max_age)
      unless @socket_path.starts_with?('/') && @client_path.starts_with?('/')
        raise ConfigurationError.new("LiveView endpoint paths must be absolute")
      end
      if @socket_path == @client_path
        raise ConfigurationError.new("LiveView socket and client paths must differ")
      end
      if @max_message_bytes <= 0
        raise ConfigurationError.new("LiveView max message size must be positive")
      end
      unless @join_timeout.positive?
        raise ConfigurationError.new("LiveView join timeout must be positive")
      end
      unless @idle_timeout.positive?
        raise ConfigurationError.new("LiveView idle timeout must be positive")
      end
      @allowed_origins = [] of String
      begin
        @allowed_origins = allowed_origins.map { |origin| normalize_origin(origin) }
      rescue error : URI::Error
        raise ConfigurationError.new("Invalid LiveView allowed origin: #{error.message}")
      end
    end

    def page(
      path : String,
      view : T.class,
      name : String = T.name,
      managed_by_scope : Bool = false,
      guards : Proc(LF::DI::Container, Array(LF::HTTP::Guard))? = nil,
      &factory : LF::DI::Container -> T
    ) : Nil forall T
      raise ConfigurationError.new("LiveView routes are already mounted") if @mounted
      if @routes.has_key?(name)
        raise ConfigurationError.new("Duplicate LiveView route name: #{name}")
      end
      if @paths.includes?(path)
        raise ConfigurationError.new("Duplicate LiveView route path: #{path}")
      end

      route_factory = ->(scope : LF::DI::Container) { factory.call(scope).as(View) }
      guard_factory = guards || ->(_scope : LF::DI::Container) { [] of LF::HTTP::Guard }
      @routes[name] = Route.new(name, path, managed_by_scope, route_factory, guard_factory)
      @paths << path
    end

    def mount(router : LF::HTTP::Router) : Nil
      raise ConfigurationError.new("LiveView endpoint is already mounted") if @mounted
      @mounted = true

      @routes.each_value do |route|
        ensure_get_available(router, route.path)
        router.get(route.path) do |context, params|
          render_initial(context, route, params)
        end
      end

      ensure_get_available(router, @client_path)
      router.get(@client_path) do |context, _params|
        context.response.headers["Content-Type"] = "text/javascript; charset=utf-8"
        context.response.headers["Cache-Control"] = "no-cache"
        context.response.print CLIENT_SOURCE
      end

      before_upgrade = ->(context : ::HTTP::Server::Context, _params : Hash(String, String)) do
        verify_origin!(context.request)
      end
      router.ws_with_context(websocket_path, before_upgrade: before_upgrade) do |websocket, _params, context|
        serve(websocket, context)
      end
    end

    private def ensure_get_available(router : LF::HTTP::Router, path : String) : Nil
      if router.http_route?(path, "GET")
        raise ConfigurationError.new("LiveView GET route conflicts with an existing route: #{path}")
      end
    end

    private def render_initial(
      context : ::HTTP::Server::Context,
      route : Route,
      params : Hash(String, String),
    ) : Nil
      scope = context.dependency_scope
      raise LF::HTTP::InternalServerError.new("DI context not initialized") unless scope

      view : View? = nil
      begin
        authorize!(route, scope, context, params, "mount")
        view = route.build(scope)
        configure_disconnected_child_views(
          view,
          "opal-live-root",
          context.request,
          params,
          context.request.resource,
          Set(String).new(["opal-live-root"]),
          0
        )
        view.__opal_mount(MountContext.new(context.request, params, context.request.resource, false))
        view.__opal_handle_params(ParamsContext.new(params, context.request.resource))
        if navigation = view.__opal_take_navigation
          target, target_uri = normalize_navigation(navigation)
          if target.kind == "patch" && !route.match_path(target_uri.path)
            raise InvalidNavigationError.new
          end
          context.response.status = ::HTTP::Status::FOUND
          context.response.headers["Location"] = target.to
          return
        end
        token = @tokens.sign(route.name, params, context.request.resource)

        context.response.headers["Content-Type"] = "text/html; charset=utf-8"
        context.response.print document(view, token)
      ensure
        view.try(&.__opal_disconnect)
        destroy_unmanaged(view, route)
      end
    end

    private def document(view : View, token : String) : String
      live_root = String.build do |html|
        html << "<main id=\"opal-live-root\" data-opal-live-root data-phx-main data-phx-session=\""
        html << HTML.escape(token) << "\" data-phx-static=\"\" data-opal-socket=\""
        html << HTML.escape(@socket_path) << "\">" << view.__opal_render.to_html << "</main>"
      end
      client_script = %(<script type="module" src="#{HTML.escape(@client_path)}"></script>)
      view.render_document(live_root, client_script)
    end

    private def serve(websocket : ::HTTP::WebSocket, context : ::HTTP::Server::Context) : Nil
      route_name : String? = nil
      updates : Channel(ChannelUpdate)? = nil
      reader_done : Channel(Nil)? = nil
      reader_finished : Channel(Nil)? = nil
      channels = {} of String => ConnectedChannel
      registrations = {} of String => ChildRegistration
      begin
        scope = context.dependency_scope
        raise LF::HTTP::InternalServerError.new("DI context not initialized") unless scope

        incoming_channel = Channel(String | Bytes).new(1)
        update_channel = Channel(ChannelUpdate).new(64)
        updates = update_channel
        done = Channel(Nil).new
        finished = Channel(Nil).new(1)
        reader_done = done
        reader_finished = finished
        spawn do
          begin
            while payload = websocket.receive?
              select
              when incoming_channel.send(payload)
              when done.receive?
                break
              end
            end
          ensure
            incoming_channel.close unless incoming_channel.closed?
            finished.send(nil)
          end
        end

        join_deadline = Time.instant + @join_timeout
        root_joined = false
        idle_deadline = Time.instant + @idle_timeout
        loop do
          deadline = root_joined ? idle_deadline : join_deadline
          remaining = deadline - Time.instant
          unless remaining.positive?
            reason = root_joined ? "idle timeout" : "join timeout"
            code = root_joined ? ::HTTP::WebSocket::CloseCode::GoingAway : ::HTTP::WebSocket::CloseCode::PolicyViolation
            close_socket(websocket, code, reason)
            return
          end

          select
          when payload = incoming_channel.receive?
            break unless payload
            message = parse_text_message(payload)

            if message.topic == "phoenix" && message.event == "heartbeat"
              send_channel_reply(websocket, message, "ok", empty_json_object)
              idle_deadline = Time.instant + @idle_timeout if root_joined
              next
            end

            case message.event
            when "phx_join"
              unless message.topic.starts_with?("lv:") && message.reference
                raise ProtocolError.new("Invalid LiveView channel join")
              end
              if channels.has_key?(message.topic)
                send_channel_error(websocket, message, "already_joined")
                next
              end
              begin
                channel = join_connected_channel(
                  websocket,
                  message,
                  context,
                  scope,
                  channels,
                  registrations,
                  update_channel
                )
              rescue error : InvalidMountTokenError
                if root_joined
                  send_channel_error(websocket, message, "invalid_mount")
                  next
                end
                raise error
              rescue error : InvalidNavigationError
                if root_joined
                  send_channel_error(websocket, message, "invalid_navigation")
                  next
                end
                raise error
              rescue error : ProtocolError | JSON::ParseException | JSON::SerializableError | TypeCastError | KeyError
                raise error
              rescue error : Exception
                if root_joined
                  Log.error(exception: error) { "Child LiveView mount failed: topic=#{message.topic}" }
                  send_channel_error(websocket, message, "mount_failed")
                  next
                end
                raise error
              end
              channels[message.topic] = channel
              if channel.root?
                if root_joined
                  raise ProtocolError.new("A LiveView socket can have only one root channel")
                end
                root_joined = true
                route_name = channel.route.name
              end
              idle_deadline = Time.instant + @idle_timeout
            when "phx_leave"
              send_channel_reply(websocket, message, "ok", empty_json_object)
              if channel = channels[message.topic]?
                unless message.join_ref == channel.join.join_ref
                  raise ProtocolError.new("LiveView channel join reference changed")
                end
                root = channel.root?
                disconnect_channel_tree(message.topic, channels, registrations)
                return if root
              end
            else
              channel = channels[message.topic]? || begin
                send_channel_error(websocket, message, "unknown_topic")
                next
              end
              unless message.join_ref == channel.join.join_ref
                raise ProtocolError.new("LiveView channel join reference changed")
              end
              idle_deadline = Time.instant + @idle_timeout
              begin
                handle_channel_message(websocket, message, channel, scope, context)
              rescue error : ChannelFailure
                raise error if channel.root?
                crash_child_channel(websocket, channel, channels, registrations)
              end
            end
          when update = update_channel.receive?
            break unless update
            if channel = channels[update.topic]?
              begin
                handle_channel_update(websocket, channel, update, scope, context)
              rescue error : ChannelFailure
                raise error if channel.root?
                crash_child_channel(websocket, channel, channels, registrations)
              end
            end
          when timeout(remaining)
            reason = root_joined ? "idle timeout" : "join timeout"
            code = root_joined ? ::HTTP::WebSocket::CloseCode::GoingAway : ::HTTP::WebSocket::CloseCode::PolicyViolation
            close_socket(websocket, code, reason)
            return
          end
        end
      rescue error : InvalidMountTokenError
        Log.warn { "LiveView rejected an invalid mount token" }
        close_socket(websocket, ::HTTP::WebSocket::CloseCode::PolicyViolation, "invalid mount")
      rescue error : LF::HTTP::Forbidden
        Log.warn { "LiveView connected mount was forbidden: route=#{route_name || "unmounted"}" }
        close_socket(websocket, ::HTTP::WebSocket::CloseCode::PolicyViolation, "forbidden")
      rescue error : UnsupportedDataError
        close_socket(websocket, ::HTTP::WebSocket::CloseCode::UnsupportedData, "text messages required")
      rescue error : MessageTooBigError
        close_socket(websocket, ::HTTP::WebSocket::CloseCode::MessageTooBig, "message too large")
      rescue error : ChannelFailure
        close_socket(
          websocket,
          ::HTTP::WebSocket::CloseCode::InternalServerError,
          error.close_reason
        )
      rescue error : ProtocolError | JSON::ParseException | JSON::SerializableError | TypeCastError | KeyError | URI::Error
        Log.warn { "LiveView protocol error: route=#{route_name || "unmounted"}" }
        close_socket(websocket, ::HTTP::WebSocket::CloseCode::ProtocolError, "invalid message")
      rescue error : Exception
        Log.error(exception: error) { "LiveView connection failed: route=#{route_name || "unmounted"}" }
        close_socket(websocket, ::HTTP::WebSocket::CloseCode::InternalServerError, "connection failed")
      ensure
        channels.values.sort_by(&.depth).reverse_each { |channel| disconnect_channel(channel) }
        channels.clear
        registrations.clear
        updates.try { |channel| channel.close unless channel.closed? }
        if completion = reader_done
          completion.close unless completion.closed?
        end
        close_socket(websocket, ::HTTP::WebSocket::CloseCode::NormalClosure) unless websocket.closed?
        if completion_signal = reader_finished
          reader_stopped = select
          when completion_signal.receive?
            true
          when timeout(1.second)
            false
          end
          unless reader_stopped
            if upgrade = context.websocket_upgrade
              begin
                upgrade.io.close unless upgrade.io.closed?
              rescue IO::Error
              end
            end
            completion_signal.receive?
          end
        end
      end
    end

    private def join_connected_channel(
      websocket : ::HTTP::WebSocket,
      join : ChannelMessage,
      context : ::HTTP::Server::Context,
      scope : LF::DI::Container,
      channels : Hash(String, ConnectedChannel),
      registrations : Hash(String, ChildRegistration),
      updates : Channel(ChannelUpdate),
    ) : ConnectedChannel
      join_data = join.payload.as_h
      token = json_string(join_data, "session")
      view : View? = nil
      channel : ConnectedChannel? = nil

      if channels.empty?
        raise InvalidMountTokenError.new unless join.topic == "lv:opal-live-root"
        mount = @tokens.verify(token)
        route = @routes[mount.route]? || raise InvalidMountTokenError.new
        resource = joined_resource(join_data["url"]?.try(&.as_s), mount.resource, context.request)
        resource_uri = URI.parse(resource)
        params = route.match_path(resource_uri.path) || raise InvalidMountTokenError.new
        authorize!(route, scope, context, params, "connect")
        view = route.build(scope)
        channel = ConnectedChannel.new(
          join,
          route,
          view,
          view.class.name,
          "opal-live-root",
          nil,
          resource,
          0
        )
        connect_view(view, channel, updates, channels, registrations)
        view.__opal_mount(MountContext.new(context.request, params, resource, true))
        view.__opal_handle_params(ParamsContext.new(params, resource))
      else
        mount = @tokens.verify_child(token)
        unless join.topic == "lv:#{mount.id}"
          raise InvalidMountTokenError.new
        end
        registration = registrations[mount.id]? || raise InvalidMountTokenError.new
        unless registration.type_name == mount.type_name &&
               registration.parent_id == mount.parent_id &&
               registration.parent_topic == mount.parent_topic &&
               registration.resource == mount.resource &&
               registration.depth == mount.depth &&
               channels.has_key?(mount.parent_topic)
          raise InvalidMountTokenError.new
        end
        route = channels[mount.parent_topic].route
        view = registration.factory.call
        channel = ConnectedChannel.new(
          join,
          route,
          view,
          mount.type_name,
          mount.id,
          mount.parent_topic,
          mount.resource,
          mount.depth
        )
        connect_view(view, channel, updates, channels, registrations)
        view.__opal_mount(MountContext.new(
          context.request,
          {} of String => String,
          mount.resource,
          true,
          mount.session,
          mount.parent_id,
          mount.id
        ))
      end

      navigation = apply_channel_navigation(channel, scope, context).try(&.navigation)
      rendered = view.__opal_render
      channel.rendered = rendered
      send_join_reply(websocket, join, build_diff(view, rendered, nil), navigation)
      channel
    rescue error
      registrations.reject! { |_id, registration| registration.parent_topic == join.topic }
      if connected = channel
        disconnect_channel(connected)
      elsif instance = view
        instance.__opal_disconnect
        destroy_nested_view(instance, join.topic)
      end
      raise error
    end

    private def connect_view(
      view : View,
      channel : ConnectedChannel,
      updates : Channel(ChannelUpdate),
      channels : Hash(String, ConnectedChannel),
      registrations : Hash(String, ChildRegistration),
    ) : Nil
      topic = channel.join.topic
      send_info = ->(info : Info) do
        begin
          updates.send(ChannelUpdate.new(topic, info))
          true
        rescue Channel::ClosedError
          false
        end
      end
      request_refresh = -> do
        begin
          select
          when updates.send(ChannelUpdate.new(topic))
            true
          else
            false
          end
        rescue Channel::ClosedError
          false
        end
      end
      view.__opal_connect(send_info, request_refresh)
      configure_connected_child_views(view, channel, channels, registrations)
    end

    private def configure_connected_child_views(
      view : View,
      channel : ConnectedChannel,
      channels : Hash(String, ConnectedChannel),
      registrations : Hash(String, ChildRegistration),
    ) : Nil
      parent_topic = channel.join.topic
      parent_id = channel.view_id
      renderer = ->(type_name : String, id : String, session : JSON::Any, factory : ChildViewFactory) do
        depth = channel.depth + 1
        if depth > MAX_CHILD_VIEW_DEPTH
          raise ChildViewNestingError.new(MAX_CHILD_VIEW_DEPTH)
        end
        if registration = registrations[id]?
          unless registration.parent_topic == parent_topic && registration.type_name == type_name
            raise DuplicateChildViewError.new(id)
          end
        end
        if active = channels["lv:#{id}"]?
          unless active.parent_topic == parent_topic && active.type_name == type_name
            raise DuplicateChildViewError.new(id)
          end
        end

        registration = ChildRegistration.new(
          type_name,
          id,
          parent_id,
          parent_topic,
          session,
          channel.resource,
          depth,
          factory
        )
        registrations[id] = registration
        token = @tokens.sign_child(
          type_name,
          id,
          parent_id,
          parent_topic,
          session,
          channel.resource,
          depth
        )
        ChildViewContent.new(id, parent_id, type_name, token, "")
      end
      finish = ->(rendered_ids : Set(String)) do
        stale = registrations.values.select do |registration|
          registration.parent_topic == parent_topic && !rendered_ids.includes?(registration.id)
        end
        stale.each { |registration| registrations.delete(registration.id) }
      end
      view.__opal_configure_child_views(renderer, finish)
    end

    private def configure_disconnected_child_views(
      view : View,
      parent_id : String,
      request : ::HTTP::Request,
      params : Hash(String, String),
      resource : String,
      all_ids : Set(String),
      depth : Int32,
    ) : Nil
      renderer = ->(type_name : String, id : String, session : JSON::Any, factory : ChildViewFactory) do
        child_depth = depth + 1
        if child_depth > MAX_CHILD_VIEW_DEPTH
          raise ChildViewNestingError.new(MAX_CHILD_VIEW_DEPTH)
        end
        unless all_ids.add?(id)
          raise DuplicateChildViewError.new(id)
        end

        child = factory.call
        begin
          configure_disconnected_child_views(
            child,
            id,
            request,
            {} of String => String,
            resource,
            all_ids,
            child_depth
          )
          child.__opal_mount(MountContext.new(
            request,
            {} of String => String,
            resource,
            false,
            session,
            parent_id,
            id
          ))
          rendered = child.__opal_render
          if child.__opal_take_navigation
            raise InvalidNavigationError.new
          end
          ChildViewContent.new(id, parent_id, type_name, "", rendered.to_html)
        ensure
          child.__opal_disconnect
          destroy_nested_view(child, "disconnected:#{id}")
        end
      end
      finish = ->(_rendered_ids : Set(String)) { }
      view.__opal_configure_child_views(renderer, finish)
    end

    private def disconnect_channel_tree(
      topic : String,
      channels : Hash(String, ConnectedChannel),
      registrations : Hash(String, ChildRegistration),
    ) : Nil
      children = channels.values.select(&.parent_topic.==(topic)).map(&.join.topic)
      children.each { |child_topic| disconnect_channel_tree(child_topic, channels, registrations) }
      registrations.reject! { |_id, registration| registration.parent_topic == topic }
      if channel = channels.delete(topic)
        disconnect_channel(channel)
      end
    end

    private def disconnect_channel(channel : ConnectedChannel) : Nil
      channel.view.__opal_disconnect
      if channel.root?
        destroy_unmanaged(channel.view, channel.route)
      else
        destroy_nested_view(channel.view, channel.join.topic)
      end
    end

    private def crash_child_channel(
      websocket : ::HTTP::WebSocket,
      channel : ConnectedChannel,
      channels : Hash(String, ConnectedChannel),
      registrations : Hash(String, ChildRegistration),
    ) : Nil
      send_channel_push(websocket, channel.join, "phx_error", empty_json_object)
      disconnect_channel_tree(channel.join.topic, channels, registrations)
    end

    private def destroy_nested_view(view : View?, identity : String) : Nil
      return unless view
      if disposable = view.as?(LF::DI::Disposable)
        disposable.destroy
      end
    rescue error : Exception
      Log.error(exception: error) { "Child LiveView cleanup failed: identity=#{identity}" }
    end

    private def apply_channel_navigation(
      channel : ConnectedChannel,
      scope : LF::DI::Container,
      context : ::HTTP::Server::Context,
    ) : NavigationResult?
      return apply_view_navigation(channel.view, channel.route, scope, context) if channel.root?

      navigation = channel.view.__opal_take_navigation
      return nil unless navigation
      if navigation.kind == "patch"
        raise InvalidNavigationError.new
      end
      normalized, _uri = normalize_navigation(navigation)
      NavigationResult.new(normalized)
    end

    private def handle_channel_message(
      websocket : ::HTTP::WebSocket,
      message : ChannelMessage,
      channel : ConnectedChannel,
      scope : LF::DI::Container,
      context : ::HTTP::Server::Context,
    ) : Nil
      view = channel.view
      rendered = channel.rendered || raise ProtocolError.new("LiveView channel is not rendered")
      case message.event
      when "event"
        reference = message.reference || raise ProtocolError.new("LiveView events require a reference")
        event_payload = message.payload.as_h
        event = json_string(event_payload, "event")
        value = event_value(event_payload)
        target = optional_json_integer(event_payload, "cid")
        begin
          event_reply = view.__opal_handle_event(target, event, value)
        rescue error : UnknownEventError
          clear_pending(view)
          send_channel_error(websocket, message, "unknown_event")
          return
        rescue error : UnknownComponentError
          clear_pending(view)
          send_channel_error(websocket, message, "unknown_target")
          return
        rescue error : Exception
          Log.error(exception: error) { "LiveView event failed: route=#{channel.route.name}" }
          raise ChannelFailure.new("event failed")
        end
        begin
          navigation = apply_channel_navigation(channel, scope, context).try(&.navigation)
        rescue error : InvalidNavigationError
          clear_pending(view)
          send_channel_error(websocket, message, "invalid_navigation")
          return
        end
        next_rendered = view.__opal_render
        diff = build_diff(view, next_rendered, rendered, event_reply)
        send_event_reply(websocket, message, diff, navigation)
        channel.rendered = next_rendered
      when "live_patch"
        unless channel.root?
          clear_pending(view)
          send_channel_error(websocket, message, "invalid_navigation")
          return
        end
        message.reference || raise ProtocolError.new("LiveView patches require a reference")
        begin
          patch_payload = message.payload.as_h
          resource = joined_resource(json_string(patch_payload, "url"), "/", context.request)
          requested = Navigation.patch(resource, "none")
          apply_patch_navigation(view, channel.route, scope, context, requested)
        rescue error : InvalidNavigationError | ProtocolError
          clear_pending(view)
          send_channel_error(websocket, message, "invalid_navigation")
          return
        rescue error : LF::HTTP::Forbidden
          raise error
        rescue error : Exception
          Log.error(exception: error) { "LiveView navigation failed: route=#{channel.route.name}" }
          raise ChannelFailure.new("navigation failed")
        end
        next_rendered = view.__opal_render
        diff = build_diff(view, next_rendered, rendered)
        send_event_reply(websocket, message, diff)
        channel.rendered = next_rendered
      else
        send_channel_error(websocket, message, "unsupported_event")
      end
    rescue error : ChannelFailure | ProtocolError | LF::HTTP::Forbidden | JSON::ParseException | JSON::SerializableError | TypeCastError | KeyError
      raise error
    rescue error : Exception
      Log.error(exception: error) { "LiveView event render failed: route=#{channel.route.name}" }
      raise ChannelFailure.new("event failed")
    end

    private def handle_channel_update(
      websocket : ::HTTP::WebSocket,
      channel : ConnectedChannel,
      update : ChannelUpdate,
      scope : LF::DI::Container,
      context : ::HTTP::Server::Context,
    ) : Nil
      view = channel.view
      rendered = channel.rendered || return
      if info = update.info
        begin
          view.handle_info(info.name, info.value)
        rescue error : Exception
          Log.error(exception: error) do
            "LiveView info failed: route=#{channel.route.name} info=#{info.name}"
          end
          raise ChannelFailure.new("info failed")
        end
      end
      navigation = apply_channel_navigation(channel, scope, context).try(&.navigation)
      next_rendered = view.__opal_render
      diff = build_diff(view, next_rendered, rendered)
      send_navigation(websocket, channel.join, navigation) if navigation
      send_channel_push(websocket, channel.join, "diff", diff) unless diff.as_h.empty?
      channel.rendered = next_rendered
    rescue error : ChannelFailure | ProtocolError | LF::HTTP::Forbidden | JSON::ParseException | JSON::SerializableError | TypeCastError | KeyError
      raise error
    rescue error : Exception
      Log.error(exception: error) { "LiveView update render failed: route=#{channel.route.name}" }
      reason = update.info ? "info failed" : "refresh failed"
      raise ChannelFailure.new(reason)
    end

    private def close_socket(
      websocket : ::HTTP::WebSocket,
      code : ::HTTP::WebSocket::CloseCode,
      message : String? = nil,
    ) : Nil
      websocket.close(code, message)
    rescue IO::Error
    end

    private def websocket_path : String
      "#{@socket_path.rstrip('/')}/websocket"
    end

    private def parse_text_message(payload : String | Bytes) : ChannelMessage
      unless payload.is_a?(String)
        raise UnsupportedDataError.new("Phoenix LiveView requires JSON text messages")
      end
      if payload.bytesize > @max_message_bytes
        raise MessageTooBigError.new("LiveView message is too large")
      end

      envelope = JSON.parse(payload).as_a
      unless envelope.size == 5
        raise ProtocolError.new("Phoenix channel messages must contain five fields")
      end
      ChannelMessage.new(
        channel_reference(envelope[0]),
        channel_reference(envelope[1]),
        envelope[2].as_s,
        envelope[3].as_s,
        envelope[4]
      )
    rescue TypeCastError
      raise ProtocolError.new("Invalid Phoenix channel message")
    end

    private def channel_reference(value : JSON::Any) : String?
      return nil if value.raw.nil?
      value.as_s
    rescue TypeCastError
      raise ProtocolError.new("Phoenix channel references must be strings or null")
    end

    private def json_string(message : Hash(String, JSON::Any), key : String) : String
      message[key].as_s
    rescue KeyError | TypeCastError
      raise ProtocolError.new("LiveView message field '#{key}' must be a string")
    end

    private def optional_json_integer(message : Hash(String, JSON::Any), key : String) : Int64?
      value = message[key]?
      return nil unless value
      return nil if value.raw.nil?
      value.as_i64
    rescue TypeCastError
      raise ProtocolError.new("LiveView message field '#{key}' must be an integer or null")
    end

    private def joined_resource(
      url : String?,
      fallback : String,
      request : ::HTTP::Request,
    ) : String
      uri = URI.parse(url || fallback)
      if uri.scheme || uri.host
        unless {"http", "https"}.includes?(uri.scheme) && uri.host
          raise ProtocolError.new("LiveView join URL must be HTTP or HTTPS")
        end
        origin = "#{uri.scheme}://#{uri.host}"
        origin += ":#{uri.port}" if uri.port
        request_origin = request.headers["Origin"]? || raise ProtocolError.new("LiveView Origin is required")
        unless normalize_origin(origin) == normalize_origin(request_origin)
          raise ProtocolError.new("LiveView URL origin does not match the socket Origin")
        end
      end
      if uri.user || uri.fragment
        raise ProtocolError.new("LiveView join URL must not contain credentials or a fragment")
      end
      path = uri.path.empty? ? "/" : uri.path
      raise ProtocolError.new("LiveView join URL must use an absolute path") unless path.starts_with?('/')
      uri.query ? "#{path}?#{uri.query}" : path
    end

    private def event_value(payload : Hash(String, JSON::Any)) : JSON::Any
      value = payload["value"]? || JSON::Any.new(nil)
      value.as_s? ? decode_form_value(value.as_s) : value
    end

    private def decode_form_value(encoded : String) : JSON::Any
      values = {} of String => Array(String)
      URI::Params.parse(encoded).each do |key, value|
        (values[key] ||= [] of String) << value
      end
      decoded = {} of String => JSON::Any
      values.each do |key, entries|
        decoded[key] = if entries.size == 1
                         JSON::Any.new(entries.first)
                       else
                         JSON::Any.new(entries.map { |entry| JSON::Any.new(entry) })
                       end
      end
      JSON::Any.new(decoded)
    rescue URI::Error
      raise ProtocolError.new("Invalid form event payload")
    end

    private def clear_pending(view : View) : Nil
      view.__opal_clear_stream_operations
      view.__opal_clear_navigation
      view.__opal_clear_pushed_events
    end

    private def empty_json_object : JSON::Any
      JSON::Any.new({} of String => JSON::Any)
    end

    private def apply_view_navigation(
      view : View,
      route : Route,
      scope : LF::DI::Container,
      context : ::HTTP::Server::Context,
    ) : NavigationResult?
      navigation = view.__opal_take_navigation
      return nil unless navigation

      if navigation.kind == "patch"
        apply_patch_navigation(view, route, scope, context, navigation)
      else
        normalized, _uri = normalize_navigation(navigation)
        NavigationResult.new(normalized)
      end
    end

    private def apply_patch_navigation(
      view : View,
      route : Route,
      scope : LF::DI::Container,
      context : ::HTTP::Server::Context,
      navigation : Navigation,
    ) : NavigationResult
      normalized, uri = normalize_navigation(navigation)
      raise InvalidNavigationError.new unless normalized.kind == "patch"
      params = route.match_path(uri.path) || raise InvalidNavigationError.new

      navigation_request = ::HTTP::Request.new(
        "GET",
        normalized.to,
        context.request.headers.dup
      )
      authorize!(route, scope, context, params, "patch", navigation_request)
      view.__opal_handle_params(ParamsContext.new(params, normalized.to))
      if view.__opal_take_navigation
        raise DuplicateNavigationError.new
      end

      token = @tokens.sign(route.name, params, normalized.to)
      NavigationResult.new(normalized, token)
    end

    private def normalize_navigation(navigation : Navigation) : {Navigation, URI}
      unless {"patch", "navigate"}.includes?(navigation.kind)
        raise InvalidNavigationError.new
      end
      unless {"push", "replace", "none"}.includes?(navigation.history)
        raise InvalidNavigationError.new
      end
      if navigation.kind == "navigate" && navigation.history == "none"
        raise InvalidNavigationError.new
      end

      uri = URI.parse(navigation.to)
      if uri.scheme || uri.host || uri.user || uri.fragment || !uri.path.starts_with?('/')
        raise InvalidNavigationError.new
      end

      resource = uri.path
      if query = uri.query
        resource += "?#{query}"
      end
      normalized = if navigation.kind == "patch"
                     Navigation.patch(resource, navigation.history)
                   else
                     Navigation.navigate(resource, navigation.history)
                   end
      {normalized, URI.parse(resource)}
    rescue URI::Error
      raise InvalidNavigationError.new
    end

    private def build_diff(
      view : View,
      rendered : Rendered,
      previous : Rendered?,
      reply : EventReply? = nil,
    ) : JSON::Any
      diff = structural_diff(rendered, previous)
      components = component_diffs(rendered, previous)
      diff["c"] = JSON::Any.new(components) unless components.empty?

      view.__opal_take_stream_operations(rendered.stream_container_ids)
      rendered.commit_streams
      pushed_events = view.__opal_take_pushed_events
      unless pushed_events.empty?
        diff["e"] = JSON::Any.new(pushed_events.map do |event|
          JSON::Any.new([JSON::Any.new(event.name), event.payload])
        end)
      end
      diff["r"] = reply.value if reply
      if title = view.title
        diff["t"] = JSON::Any.new(title)
      end
      JSON::Any.new(diff)
    end

    private def structural_diff(
      rendered : Rendered,
      previous : Rendered?,
      *,
      component_root : Bool = false,
    ) : Hash(String, JSON::Any)
      diff = {} of String => JSON::Any
      changes = previous.try { |old| rendered.diff(old) }
      if changes
        previous_dynamics = previous.try(&.dynamics)
        changes.each do |index, dynamic|
          old_dynamic = previous_dynamics.try { |dynamics| dynamics[index]? }
          diff[index.to_s] = dynamic_to_json(dynamic, old_dynamic)
        end
      else
        diff["s"] = JSON::Any.new(rendered.statics.map { |static| JSON::Any.new(static) })
        rendered.dynamics.each_with_index do |dynamic, index|
          diff[index.to_s] = dynamic_to_json(dynamic, nil)
        end
        diff["r"] = JSON::Any.new(1_i64) if component_root
      end
      diff
    end

    private def component_diffs(
      rendered : Rendered,
      previous : Rendered?,
    ) : Hash(String, JSON::Any)
      current_components = rendered.component_contents
      previous_components = previous.try(&.component_contents) || {} of Int64 => ComponentContent
      diffs = {} of String => JSON::Any
      current_components.each do |cid, component|
        previous_rendered = previous_components[cid]?.try(&.rendered)
        component_diff = structural_diff(
          component.rendered,
          previous_rendered,
          component_root: true
        )
        unless component_diff.empty?
          diffs[cid.to_s] = JSON::Any.new(component_diff)
        end
      end
      diffs
    end

    private def dynamic_to_json(
      dynamic : RenderedDynamic,
      previous : RenderedDynamic?,
    ) : JSON::Any
      case dynamic
      when String           then JSON::Any.new(dynamic)
      when StreamContent    then dynamic.to_diff
      when ComponentContent then JSON::Any.new(dynamic.cid)
      when KeyedContent     then keyed_to_json(dynamic, previous.as?(KeyedContent))
      when ChildViewContent then JSON::Any.new(dynamic.to_html)
      else                       raise Error.new("Unsupported LiveView dynamic value")
      end
    end

    private def keyed_to_json(
      content : KeyedContent,
      previous : KeyedContent?,
    ) : JSON::Any
      full = previous.nil? || previous.fingerprint != content.fingerprint
      previous_entries = previous.try(&.entries) || [] of KeyedEntry
      previous_by_key = {} of String => {Int32, Rendered}
      previous_entries.each_with_index do |entry, index|
        previous_by_key[entry.key] = {index, entry.rendered}
      end

      keyed = {"kc" => JSON::Any.new(content.entries.size.to_i64)}
      moved = false
      content.entries.each_with_index do |entry, index|
        if !full && (old = previous_by_key[entry.key]?)
          previous_index, previous_rendered = old
          entry_diff = keyed_entry_diff(entry.rendered, previous_rendered)
          if previous_index == index
            unless entry_diff.empty?
              keyed[index.to_s] = JSON::Any.new(entry_diff)
            end
          else
            moved = true
            keyed[index.to_s] = if entry_diff.empty?
                                  JSON::Any.new(previous_index.to_i64)
                                else
                                  JSON::Any.new([
                                    JSON::Any.new(previous_index.to_i64),
                                    JSON::Any.new(entry_diff),
                                  ])
                                end
          end
        else
          keyed[index.to_s] = JSON::Any.new(keyed_entry_diff(entry.rendered, nil))
        end
      end
      keyed["km"] = JSON::Any.new(true) if moved

      diff = {"k" => JSON::Any.new(keyed)}
      if full
        diff["s"] = JSON::Any.new(content.statics.map { |static| JSON::Any.new(static) })
      end
      JSON::Any.new(diff)
    end

    private def keyed_entry_diff(
      rendered : Rendered,
      previous : Rendered?,
    ) : Hash(String, JSON::Any)
      changes = previous.try { |old| rendered.diff(old) }
      dynamics = changes || rendered.dynamics.each_with_index.to_h do |dynamic, index|
        {index, dynamic}
      end
      previous_dynamics = previous.try(&.dynamics)
      dynamics.each_with_object({} of String => JSON::Any) do |(index, dynamic), diff|
        old_dynamic = previous_dynamics.try { |values| values[index]? }
        diff[index.to_s] = dynamic_to_json(dynamic, old_dynamic)
      end
    end

    private def send_join_reply(
      websocket : ::HTTP::WebSocket,
      join : ChannelMessage,
      diff : JSON::Any,
      navigation : Navigation?,
    ) : Nil
      if navigation && navigation.kind == "navigate"
        response = {"live_redirect" => navigation_payload(navigation)}
        send_channel_reply(websocket, join, "error", JSON::Any.new(response))
        return
      end

      response = {
        "rendered"         => diff,
        "liveview_version" => JSON::Any.new(LIVE_VIEW_VERSION),
      }
      if navigation
        response["live_patch"] = navigation_payload(navigation)
      end
      send_channel_reply(websocket, join, "ok", JSON::Any.new(response))
    end

    private def send_event_reply(
      websocket : ::HTTP::WebSocket,
      message : ChannelMessage,
      diff : JSON::Any,
      navigation : Navigation? = nil,
    ) : Nil
      response = {} of String => JSON::Any
      response["diff"] = diff unless diff.as_h.empty?
      if navigation
        key = navigation.kind == "patch" ? "live_patch" : "live_redirect"
        response[key] = navigation_payload(navigation)
      end
      send_channel_reply(websocket, message, "ok", JSON::Any.new(response))
    end

    private def send_channel_reply(
      websocket : ::HTTP::WebSocket,
      message : ChannelMessage,
      status : String,
      response : JSON::Any,
    ) : Nil
      websocket.send(JSON.build do |json|
        json.array do
          write_optional_string(json, message.join_ref)
          write_optional_string(json, message.reference)
          json.string(message.topic)
          json.string("phx_reply")
          json.object do
            json.field "status", status
            json.field "response" do
              response.to_json(json)
            end
          end
        end
      end)
    end

    private def send_channel_push(
      websocket : ::HTTP::WebSocket,
      channel : ChannelMessage,
      event : String,
      payload : JSON::Any,
    ) : Nil
      websocket.send(JSON.build do |json|
        json.array do
          write_optional_string(json, channel.join_ref)
          json.null
          json.string(channel.topic)
          json.string(event)
          payload.to_json(json)
        end
      end)
    end

    private def send_channel_error(
      websocket : ::HTTP::WebSocket,
      message : ChannelMessage,
      reason : String,
    ) : Nil
      response = JSON::Any.new({"reason" => JSON::Any.new(reason)})
      send_channel_reply(websocket, message, "error", response)
    end

    private def send_navigation(
      websocket : ::HTTP::WebSocket,
      channel : ChannelMessage,
      navigation : Navigation,
    ) : Nil
      event = navigation.kind == "patch" ? "live_patch" : "live_redirect"
      send_channel_push(websocket, channel, event, navigation_payload(navigation))
    end

    private def navigation_payload(navigation : Navigation) : JSON::Any
      JSON::Any.new({
        "to"   => JSON::Any.new(navigation.to),
        "kind" => JSON::Any.new(navigation.history),
      })
    end

    private def write_optional_string(json : JSON::Builder, value : String?) : Nil
      value ? json.string(value) : json.null
    end

    private def destroy_unmanaged(view : View?, route : Route) : Nil
      return unless view
      return if route.managed_by_scope?
      if disposable = view.as?(LF::DI::Disposable)
        disposable.destroy
      end
    rescue error : Exception
      Log.error(exception: error) { "LiveView cleanup failed: route=#{route.name}" }
    end

    private def authorize!(
      route : Route,
      scope : LF::DI::Container,
      context : ::HTTP::Server::Context,
      params : Hash(String, String),
      action : String,
      request_override : ::HTTP::Request? = nil,
    ) : Nil
      execution_context = LF::HTTP::ExecutionContext.new(
        context,
        params,
        route.name,
        action,
        request_override
      )
      route.guards(scope).each do |guard|
        raise LF::HTTP::Forbidden.new unless guard.can_activate(execution_context)
      end
    end

    private def verify_origin!(request : ::HTTP::Request) : Nil
      origin = request.headers["Origin"]? || raise LF::HTTP::Forbidden.new("Origin required")
      if @allowed_origins.empty?
        raise LF::HTTP::Forbidden.new("Origin not allowed") unless same_origin?(origin, request)
      elsif !@allowed_origins.includes?(normalize_origin(origin))
        raise LF::HTTP::Forbidden.new("Origin not allowed")
      end
    rescue URI::Error
      raise LF::HTTP::Forbidden.new("Origin not allowed")
    end

    private def same_origin?(origin : String, request : ::HTTP::Request) : Bool
      origin_uri = URI.parse(origin)
      return false unless {"http", "https"}.includes?(origin_uri.scheme)
      return false if origin_uri.user || origin_uri.query || origin_uri.fragment
      return false unless origin_uri.path.empty?
      return false unless origin_uri.host

      host = request.headers["Host"]? || return false
      request_uri = URI.parse("#{origin_uri.scheme}://#{host}")
      origin_uri.host.try(&.downcase) == request_uri.host.try(&.downcase) &&
        effective_port(origin_uri) == effective_port(request_uri)
    end

    private def normalize_origin(origin : String) : String
      uri = URI.parse(origin)
      scheme = uri.scheme || raise URI::Error.new("invalid origin")
      host = uri.host || raise URI::Error.new("invalid origin")
      raise URI::Error.new("invalid origin") unless {"http", "https"}.includes?(scheme)
      unless uri.path.empty? || uri.path == "/"
        raise URI::Error.new("invalid origin")
      end
      raise URI::Error.new("invalid origin") if uri.user || uri.query || uri.fragment
      "#{scheme.downcase}://#{host.downcase}:#{effective_port(uri)}"
    end

    private def effective_port(uri : URI) : Int32
      uri.port || (uri.scheme == "https" ? 443 : 80)
    end
  end
end
