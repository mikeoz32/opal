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
    PROTOCOL_VERSION        = 2
    LEGACY_PROTOCOL_VERSION = 1
    SOCKET_PATH             = "/_opal/live"
    CLIENT_PATH             = "/_opal/live.js"
    CLIENT_SOURCE           = {{ read_file("#{__DIR__}/../../../assets/opal_live_view.js") }}

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
      router.ws_with_context(@socket_path, before_upgrade: before_upgrade) do |websocket, _params, context|
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
        html << "<main id=\"opal-live-root\" data-opal-live-root data-opal-token=\""
        html << HTML.escape(token) << "\" data-opal-socket=\""
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

        join_payload = select
        when payload = incoming_channel.receive?
          payload || raise ProtocolError.new("LiveView connection closed before join")
        when timeout(@join_timeout)
          close_socket(websocket, ::HTTP::WebSocket::CloseCode::PolicyViolation, "join timeout")
          return
        end
        unless join_payload.is_a?(String)
          close_socket(websocket, ::HTTP::WebSocket::CloseCode::UnsupportedData, "text messages required")
          return
        end
        if join_payload.bytesize > @max_message_bytes
          close_socket(websocket, ::HTTP::WebSocket::CloseCode::MessageTooBig, "message too large")
          return
        end

        join = parse_message(join_payload)
        unless string(join, "type") == "join"
          raise ProtocolError.new("The first LiveView message must be join")
        end
        protocol = integer(join, "protocol")
        unless {LEGACY_PROTOCOL_VERSION, PROTOCOL_VERSION}.includes?(protocol)
          raise ProtocolError.new("Unsupported LiveView protocol version")
        end

        mount = @tokens.verify(string(join, "token"))
        route_name = mount.route
        route = @routes[mount.route]? || raise InvalidMountTokenError.new
        connected_route = route
        scope = context.dependency_scope
        raise LF::HTTP::InternalServerError.new("DI context not initialized") unless scope

        authorize!(route, scope, context, mount.params, "connect")
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
        view.__opal_mount(MountContext.new(context.request, mount.params, mount.resource, true))
        view.__opal_handle_params(ParamsContext.new(mount.params, mount.resource))
        navigation_result = apply_view_navigation(view, route, scope, context)
        version = 0_i64
        rendered = view.__opal_render
        send_render(
          websocket,
          view,
          rendered,
          nil,
          protocol,
          version,
          navigation: navigation_result.try(&.navigation),
          token: navigation_result.try(&.token)
        )

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
            unless payload.is_a?(String)
              close_socket(websocket, ::HTTP::WebSocket::CloseCode::UnsupportedData, "text messages required")
              return
            end
            if payload.bytesize > @max_message_bytes
              close_socket(websocket, ::HTTP::WebSocket::CloseCode::MessageTooBig, "message too large")
              return
            end

            message = parse_message(payload)
            case string(message, "type")
            when "heartbeat"
              send_heartbeat(websocket, message["ref"]?)
            when "event"
              reference = integer(message, "ref")
              client_version = integer(message, "version")
              if client_version != version
                send_render(
                  websocket,
                  view,
                  rendered,
                  rendered,
                  protocol,
                  version,
                  reference: reference,
                  status: "stale"
                )
                next
              end

              event = string(message, "event")
              value = message["value"]? || JSON::Any.new(nil)
              target = optional_integer(message, "target")
              begin
                event_reply = view.__opal_handle_event(target, event, value)
              rescue error : UnknownEventError
                view.__opal_clear_stream_operations
                view.__opal_clear_navigation
                view.__opal_clear_pushed_events
                send_error(websocket, "unknown_event", reference)
                next
              rescue error : UnknownComponentError
                view.__opal_clear_stream_operations
                view.__opal_clear_navigation
                view.__opal_clear_pushed_events
                send_error(websocket, "unknown_target", reference)
                next
              rescue error : Exception
                Log.error(exception: error) { "LiveView event failed: route=#{route.name}" }
                close_socket(websocket, ::HTTP::WebSocket::CloseCode::InternalServerError, "event failed")
                return
              end
              navigation_result = apply_view_navigation(view, route, scope, context)
              version += 1
              next_rendered = view.__opal_render
              send_render(
                websocket,
                view,
                next_rendered,
                rendered,
                protocol,
                version,
                reference: reference,
                status: "ok",
                navigation: navigation_result.try(&.navigation),
                token: navigation_result.try(&.token),
                reply: event_reply
              )
              rendered = next_rendered
            when "patch"
              raise ProtocolError.new("LiveView navigation requires protocol version 2") if protocol == LEGACY_PROTOCOL_VERSION
              reference = integer(message, "ref")
              client_version = integer(message, "version")
              if client_version != version
                send_render(
                  websocket,
                  view,
                  rendered,
                  rendered,
                  protocol,
                  version,
                  reference: reference,
                  status: "stale"
                )
                next
              end

              begin
                requested = Navigation.patch(string(message, "to"), string(message, "history"))
                navigation_result = apply_patch_navigation(view, route, scope, context, requested)
              rescue error : InvalidNavigationError
                view.__opal_clear_stream_operations
                view.__opal_clear_navigation
                view.__opal_clear_pushed_events
                send_error(websocket, "invalid_navigation", reference)
                next
              rescue error : LF::HTTP::Forbidden
                raise error
              rescue error : Exception
                Log.error(exception: error) { "LiveView navigation failed: route=#{route.name}" }
                close_socket(websocket, ::HTTP::WebSocket::CloseCode::InternalServerError, "navigation failed")
                return
              end

              version += 1
              next_rendered = view.__opal_render
              send_render(
                websocket,
                view,
                next_rendered,
                rendered,
                protocol,
                version,
                reference: reference,
                status: "ok",
                navigation: navigation_result.navigation,
                token: navigation_result.token
              )
              rendered = next_rendered
            else
              raise ProtocolError.new("Unsupported LiveView message type")
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
            navigation_result = apply_view_navigation(view, route, scope, context)
            version += 1
            next_rendered = view.__opal_render
            send_render(
              websocket,
              view,
              next_rendered,
              rendered,
              protocol,
              version,
              navigation: navigation_result.try(&.navigation),
              token: navigation_result.try(&.token)
            )
            rendered = next_rendered
          when refresh_channel.receive
            version += 1
            next_rendered = view.__opal_render
            send_render(websocket, view, next_rendered, rendered, protocol, version)
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
      rescue error : ProtocolError | JSON::ParseException | JSON::SerializableError | TypeCastError | KeyError
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

    private def parse_message(payload : String) : Hash(String, JSON::Any)
      JSON.parse(payload).as_h
    end

    private def string(message : Hash(String, JSON::Any), key : String) : String
      message[key].as_s
    rescue KeyError | TypeCastError
      raise ProtocolError.new("LiveView message field '#{key}' must be a string")
    end

    private def integer(message : Hash(String, JSON::Any), key : String) : Int64
      message[key].as_i64
    rescue KeyError | TypeCastError
      raise ProtocolError.new("LiveView message field '#{key}' must be an integer")
    end

    private def optional_integer(message : Hash(String, JSON::Any), key : String) : Int64?
      value = message[key]?
      return nil unless value
      return nil if value.raw.nil?
      value.as_i64
    rescue TypeCastError
      raise ProtocolError.new("LiveView message field '#{key}' must be an integer or null")
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

    private def send_render(
      websocket : ::HTTP::WebSocket,
      view : View,
      rendered : Rendered,
      previous : Rendered?,
      protocol : Int64,
      version : Int64,
      *,
      reference : Int64? = nil,
      status : String? = nil,
      navigation : Navigation? = nil,
      token : String? = nil,
      reply : EventReply? = nil,
    ) : Nil
      changes = previous.try { |old| rendered.diff(old) }
      streams = view.__opal_take_stream_operations
      pushed_events = view.__opal_take_pushed_events
      if protocol == LEGACY_PROTOCOL_VERSION && (!streams.empty? || navigation || !pushed_events.empty? || reply)
        raise ProtocolError.new("LiveView streams, navigation, and custom events require protocol version 2")
      end
      websocket.send(JSON.build do |json|
        json.object do
          json.field "type", "render"
          json.field "protocol", protocol
          json.field "version", version
          if protocol == LEGACY_PROTOCOL_VERSION
            json.field "html", rendered.to_html
          elsif changes
            json.field "fingerprint", rendered.fingerprint
            json.field "diff" do
              json.object do
                changes.each do |index, dynamic|
                  json.field index.to_s, dynamic
                end
              end
            end
          else
            json.field "rendered" do
              json.object do
                json.field "fingerprint", rendered.fingerprint
                json.field "statics" do
                  rendered.statics.to_json(json)
                end
                json.field "dynamics" do
                  rendered.dynamics.to_json(json)
                end
              end
            end
          end
          unless streams.empty?
            json.field "streams" do
              streams.to_json(json)
            end
          end
          unless pushed_events.empty?
            json.field "events" do
              pushed_events.to_json(json)
            end
          end
          if navigation
            json.field "navigation" do
              navigation.to_json(json)
            end
          end
          if token
            json.field "token", token
          end
          if reply
            json.field "reply" do
              reply.value.to_json(json)
            end
          end
          if reference
            json.field "ref", reference
          end
          if status
            json.field "status", status
          end
          if title = view.title
            json.field "title", title
          end
        end
      end)
    end

    private def send_heartbeat(websocket : ::HTTP::WebSocket, reference : JSON::Any?) : Nil
      websocket.send(JSON.build do |json|
        json.object do
          json.field "type", "heartbeat"
          json.field "ref" do
            if reference
              reference.to_json(json)
            else
              json.null
            end
          end
        end
      end)
    end

    private def send_error(websocket : ::HTTP::WebSocket, reason : String, reference : Int64? = nil) : Nil
      websocket.send(JSON.build do |json|
        json.object do
          json.field "type", "error"
          json.field "reason", reason
          if reference
            json.field "ref", reference
          end
        end
      end)
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
