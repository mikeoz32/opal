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
    LIVE_VIEW_VERSION = "1.2.11"
    SOCKET_PATH       = "/_opal/live"
    CLIENT_PATH       = "/_opal/live.js"
    CLIENT_SOURCE     = {{ read_file("#{__DIR__}/../../../assets/opal_live_view.js") }}

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
      connected_route : Route? = nil
      connected_view : View? = nil
      updates : Channel(Info)? = nil
      refreshes : Channel(Nil)? = nil
      reader_done : Channel(Nil)? = nil
      reader_finished : Channel(Nil)? = nil
      begin
        incoming_channel = Channel(String | Bytes).new(1)
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
        join = loop do
          remaining_join = join_deadline - Time.instant
          unless remaining_join.positive?
            close_socket(websocket, ::HTTP::WebSocket::CloseCode::PolicyViolation, "join timeout")
            return
          end
          candidate = select
          when payload = incoming_channel.receive?
            parse_text_message(payload || raise ProtocolError.new("LiveView connection closed before join"))
          when timeout(remaining_join)
            close_socket(websocket, ::HTTP::WebSocket::CloseCode::PolicyViolation, "join timeout")
            return
          end

          if candidate.topic == "phoenix" && candidate.event == "heartbeat"
            send_channel_reply(websocket, candidate, "ok", empty_json_object)
          elsif candidate.event == "phx_leave"
            send_channel_reply(websocket, candidate, "ok", empty_json_object)
          elsif candidate.event == "phx_join" && candidate.topic.starts_with?("lv:") && candidate.reference
            break candidate
          else
            raise ProtocolError.new("LiveView connection requires a phx_join message")
          end
        end

        join_data = join.payload.as_h
        mount = @tokens.verify(json_string(join_data, "session"))
        route_name = mount.route
        route = @routes[mount.route]? || raise InvalidMountTokenError.new
        connected_route = route
        resource = joined_resource(join_data["url"]?.try(&.as_s), mount.resource, context.request)
        resource_uri = URI.parse(resource)
        params = route.match_path(resource_uri.path) || raise InvalidMountTokenError.new
        scope = context.dependency_scope
        raise LF::HTTP::InternalServerError.new("DI context not initialized") unless scope

        authorize!(route, scope, context, params, "connect")
        view = route.build(scope)
        connected_view = view
        update_channel = Channel(Info).new(32)
        refresh_channel = Channel(Nil).new(1)
        updates = update_channel
        refreshes = refresh_channel
        send_info = ->(info : Info) do
          begin
            update_channel.send(info)
            true
          rescue Channel::ClosedError
            false
          end
        end
        request_refresh = -> do
          select
          when refresh_channel.send(nil)
            true
          else
            false
          end
        end
        view.__opal_connect(send_info, request_refresh)
        view.__opal_mount(MountContext.new(context.request, params, resource, true))
        view.__opal_handle_params(ParamsContext.new(params, resource))
        navigation_result = apply_view_navigation(view, route, scope, context)
        rendered = view.__opal_render
        join_diff = build_diff(view, rendered, nil)
        send_join_reply(websocket, join, join_diff, navigation_result.try(&.navigation))

        idle_deadline = Time.instant + @idle_timeout
        loop do
          remaining_idle = idle_deadline - Time.instant
          unless remaining_idle.positive?
            close_socket(websocket, ::HTTP::WebSocket::CloseCode::GoingAway, "idle timeout")
            return
          end

          select
          when payload = incoming_channel.receive?
            break unless payload
            idle_deadline = Time.instant + @idle_timeout
            message = parse_text_message(payload)

            if message.topic == "phoenix" && message.event == "heartbeat"
              send_channel_reply(websocket, message, "ok", empty_json_object)
              next
            end
            unless message.topic == join.topic && message.join_ref == join.join_ref
              raise ProtocolError.new("LiveView channel topic or join reference changed")
            end

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
                next
              rescue error : UnknownComponentError
                clear_pending(view)
                send_channel_error(websocket, message, "unknown_target")
                next
              rescue error : Exception
                Log.error(exception: error) { "LiveView event failed: route=#{route.name}" }
                close_socket(websocket, ::HTTP::WebSocket::CloseCode::InternalServerError, "event failed")
                return
              end
              navigation = apply_view_navigation(view, route, scope, context).try(&.navigation)
              next_rendered = view.__opal_render
              diff = build_diff(view, next_rendered, rendered, event_reply)
              send_event_reply(websocket, message, diff, navigation)
              rendered = next_rendered
            when "live_patch"
              message.reference || raise ProtocolError.new("LiveView patches require a reference")
              begin
                patch_payload = message.payload.as_h
                resource = joined_resource(json_string(patch_payload, "url"), "/", context.request)
                requested = Navigation.patch(resource, "none")
                apply_patch_navigation(view, route, scope, context, requested)
              rescue error : InvalidNavigationError | ProtocolError
                clear_pending(view)
                send_channel_error(websocket, message, "invalid_navigation")
                next
              rescue error : LF::HTTP::Forbidden
                raise error
              rescue error : Exception
                Log.error(exception: error) { "LiveView navigation failed: route=#{route.name}" }
                close_socket(websocket, ::HTTP::WebSocket::CloseCode::InternalServerError, "navigation failed")
                return
              end
              next_rendered = view.__opal_render
              diff = build_diff(view, next_rendered, rendered)
              send_event_reply(websocket, message, diff)
              rendered = next_rendered
            when "phx_leave"
              send_channel_reply(websocket, message, "ok", empty_json_object)
              return
            else
              send_channel_error(websocket, message, "unsupported_event")
            end
          when info = update_channel.receive?
            break unless info
            begin
              view.handle_info(info.name, info.value)
            rescue error : Exception
              Log.error(exception: error) { "LiveView info failed: route=#{route.name} info=#{info.name}" }
              close_socket(websocket, ::HTTP::WebSocket::CloseCode::InternalServerError, "info failed")
              return
            end
            navigation = apply_view_navigation(view, route, scope, context).try(&.navigation)
            next_rendered = view.__opal_render
            diff = build_diff(view, next_rendered, rendered)
            send_navigation(websocket, join, navigation) if navigation
            send_channel_push(websocket, join, "diff", diff) unless diff.as_h.empty?
            rendered = next_rendered
          when refresh_channel.receive
            next_rendered = view.__opal_render
            diff = build_diff(view, next_rendered, rendered)
            send_channel_push(websocket, join, "diff", diff) unless diff.as_h.empty?
            rendered = next_rendered
          when timeout(remaining_idle)
            close_socket(websocket, ::HTTP::WebSocket::CloseCode::GoingAway, "idle timeout")
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
      rescue error : ProtocolError | JSON::ParseException | JSON::SerializableError | TypeCastError | KeyError | URI::Error
        Log.warn { "LiveView protocol error: route=#{route_name || "unmounted"}" }
        close_socket(websocket, ::HTTP::WebSocket::CloseCode::ProtocolError, "invalid message")
      rescue error : Exception
        Log.error(exception: error) { "LiveView connection failed: route=#{route_name || "unmounted"}" }
        close_socket(websocket, ::HTTP::WebSocket::CloseCode::InternalServerError, "connection failed")
      ensure
        connected_view.try(&.__opal_disconnect)
        updates.try { |channel| channel.close unless channel.closed? }
        refreshes.try { |channel| channel.close unless channel.closed? }
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
        if view = connected_view
          if route = connected_route
            destroy_unmanaged(view, route)
          end
        end
      end
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
        changes.each do |index, dynamic|
          diff[index.to_s] = dynamic_to_json(dynamic)
        end
      else
        diff["s"] = JSON::Any.new(rendered.statics.map { |static| JSON::Any.new(static) })
        rendered.dynamics.each_with_index do |dynamic, index|
          diff[index.to_s] = dynamic_to_json(dynamic)
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

    private def dynamic_to_json(dynamic : RenderedDynamic) : JSON::Any
      case dynamic
      when String           then JSON::Any.new(dynamic)
      when StreamContent    then dynamic.to_diff
      when ComponentContent then JSON::Any.new(dynamic.cid)
      else                       raise Error.new("Unsupported LiveView dynamic value")
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
      view.as?(LF::DI::Disposable).try(&.destroy)
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
