require "http/server"
require "../../opal"
require "sync/mutex"
require "../live_view/autoconfig"

module LF::AutoConfig
  annotation HTTP
  end
end

module LF::HTTP::AutoConfig
  class Error < Exception
  end

  class ConfigurationError < Error
    def initialize(reason : String)
      super("Invalid HTTP configuration: #{reason}")
    end
  end

  class DrainTimeoutError < Error
    include LF::ApplicationExtension::StopIncomplete

    getter active_requests : Int32

    def initialize(@active_requests)
      super("HTTP drain timed out with #{@active_requests} active request(s)")
    end
  end

  private class ConnectionState
    getter io : IO
    property? active = false
    property? closing = false
    property completion : RequestCompletion? = nil

    def initialize(@io)
    end
  end

  private class RequestCompletion
    @handler_finished = false
    @output_finished = false
    @upgraded = false
    @reported = false
    @scope_released = false
    @lock = Mutex.new

    def initialize(
      @requests : ConnectionDrainHandler,
      @connection : ConnectionState,
      @context : ::HTTP::Server::Context,
      @scope : LF::DI::Container,
    )
    end

    def handler_finished(upgraded : Bool) : Nil
      report = @lock.synchronize do
        @handler_finished = true
        @upgraded = upgraded
        report?
      end
      if upgraded
        release_scope
      elsif report
        finish
      end
    end

    def output_finished : Nil
      report = @lock.synchronize do
        @output_finished = true
        report?
      end
      finish if report
    end

    def connection_finished : Nil
      report = @lock.synchronize do
        next false if @reported
        @reported = true
      end
      finish if report
    end

    private def report? : Bool
      return false if @reported || @upgraded || !@handler_finished || !@output_finished
      @reported = true
    end

    private def finish : Nil
      scope_error : Exception? = nil
      begin
        release_scope
      rescue error : Exception
        scope_error = error
      ensure
        @requests.request_finished(@connection)
      end
      raise scope_error.as(Exception) if scope_error
    end

    private def release_scope : Nil
      release = @lock.synchronize do
        next false if @scope_released
        @scope_released = true
      end
      return unless release

      begin
        @scope.exit
      ensure
        if @context.dependency_scope.same?(@scope)
          @context.dependency_scope = nil
        end
      end
    end
  end

  private class CompletionOutput < IO
    @closed = false

    def initialize(@output : IO, @completion : RequestCompletion)
    end

    def read(slice : Bytes) : NoReturn
      raise IO::Error.new("response output is write-only")
    end

    def write(slice : Bytes) : Nil
      @output.write(slice)
    end

    def flush : Nil
      @output.flush
    end

    def close : Nil
      return if @closed
      @output.close
    ensure
      unless @closed
        @closed = true
        @completion.output_finished
      end
    end

    def closed? : Bool
      @closed
    end
  end

  # Tracks the complete connection lifetime, including response finalization,
  # idle keep-alive sockets, and work handed to an HTTP upgrade callback.
  private class ConnectionDrainHandler
    include ::HTTP::Handler

    @connections = [] of ConnectionState
    @connection_by_fiber = {} of Fiber => ConnectionState
    @active = 0
    @draining = false
    @lock = Mutex.new
    @idle = Channel(Nil).new

    def initialize(@handler : ::HTTP::Handler, @scope_provider : LF::DI::ScopeProvider)
    end

    def connection_started(io : IO) : ConnectionState
      state = ConnectionState.new(io)
      @lock.synchronize { @connections << state }
      state
    end

    def attach_connection(state : ConnectionState) : Nil
      @lock.synchronize { @connection_by_fiber[Fiber.current] = state }
    end

    def connection_finished(state : ConnectionState) : Nil
      completion_error : Exception? = nil
      begin
        state.completion.try(&.connection_finished)
      rescue error : Exception
        completion_error = error
      ensure
        @lock.synchronize do
          @connection_by_fiber.delete(Fiber.current)
          @connections.delete(state)
          if state.active?
            state.active = false
            @active -= 1
          end
          close_idle_signal
        end
      end
      raise completion_error.as(Exception) if completion_error
    end

    def call(context : ::HTTP::Server::Context) : Nil
      completion, connection = request_started(context)
      unless completion
        connection.try(&.io.close)
        raise IO::Error.new("HTTP server is draining")
      end

      context.response.output = CompletionOutput.new(context.response.output, completion)
      @handler.call(context)
    ensure
      completion.try(&.handler_finished(!context.response.upgrade_handler.nil?))
    end

    def request_finished(connection : ConnectionState) : Nil
      close = @lock.synchronize do
        if connection.active?
          connection.active = false
          @active -= 1
        end
        connection.completion = nil
        should_close = @draining && !connection.closing?
        connection.closing = true if should_close
        close_idle_signal
        should_close
      end
      connection.io.close if close
    rescue IO::Error
      # A peer may close concurrently with the drain transition.
    end

    def drain_until(deadline : Time::Instant) : Int32
      close = @lock.synchronize do
        @draining = true
        idle = @connections.select { |connection| !connection.active? && !connection.closing? }
        idle.each { |connection| connection.closing = true }
        close_idle_signal
        idle.map(&.io)
      end
      close.each do |io|
        io.close
      rescue IO::Error
        # The peer may already have closed an idle keep-alive connection.
      end
      return 0 if @idle.closed?

      remaining = deadline - Time.instant
      return active_requests unless remaining.positive?

      select
      when @idle.receive?
        0
      when timeout(remaining)
        active_requests
      end
    end

    def force_close : Nil
      close = @lock.synchronize do
        @connections.each { |connection| connection.closing = true }
        @connections.map(&.io)
      end
      close.each do |io|
        io.close
      rescue IO::Error
        # A request may complete while the timeout path closes transports.
      end
    end

    def drained? : Bool
      @lock.synchronize { @active == 0 }
    end

    private def request_started(context : ::HTTP::Server::Context) : {RequestCompletion?, ConnectionState?}
      connection = @lock.synchronize do
        current_connection = @connection_by_fiber[Fiber.current]?
        return {nil, nil} unless current_connection
        return {nil, current_connection} if @draining || current_connection.closing?
        current_connection.active = true
        @active += 1
        current_connection
      end

      begin
        scope = @scope_provider.enter_scope("request")
        context.dependency_scope = scope
        completion = RequestCompletion.new(self, connection, context, scope)
        @lock.synchronize { connection.completion = completion }
        {completion, connection}
      rescue error : Exception
        context.dependency_scope = nil
        request_finished(connection)
        raise error
      end
    end

    private def active_requests : Int32
      @lock.synchronize { @active }
    end

    private def close_idle_signal : Nil
      @idle.close if @draining && @active == 0 && !@idle.closed?
    end
  end

  private class DrainingHttpServer < ::HTTP::Server
    def initialize(@requests : ConnectionDrainHandler)
      super(@requests)
    end

    protected def dispatch(io) : Nil
      connection = @requests.connection_started(io)
      spawn do
        @requests.attach_connection(connection)
        handle_client(io)
      ensure
        @requests.connection_finished(connection)
      end
    end
  end

  class Extension
    include LF::ApplicationExtension

    getter configured_host = "0.0.0.0"
    getter configured_port = 8080
    getter configured_drain_timeout = 30.seconds
    getter websocket_shutdown_timeout_ms = 5000

    @server : DrainingHttpServer?
    @requests : ConnectionDrainHandler?
    @address : Socket::IPAddress?
    @stop_lock = Mutex.new
    @stop_done = Channel(Nil).new
    @stop_started = false
    @stop_in_progress = false
    @stop_complete = false
    @stop_error : Exception?
    @websocket_connections = LF::HTTP::WebSocketConnectionRegistry.new

    def initialize(&@app_builder : LF::ApplicationContext -> LF::HTTP::App)
    end

    def configure(context : LF::ApplicationContext) : Nil
      config = context.resolve(LF::ConfigService)

      begin
        @configured_host = config.get("http.host", "0.0.0.0")
        @configured_port = config.get("http.port", 8080)
        drain_timeout_ms = config.get("http.drain_timeout_ms", 30_000)
        @websocket_shutdown_timeout_ms = config.get("http.websocket.shutdown_timeout_ms", 5000)
        unless 0 <= @configured_port <= 65_535
          raise "http.port must be between 0 and 65535"
        end
        raise "http.drain_timeout_ms must be positive" unless drain_timeout_ms > 0
        raise "http.websocket.shutdown_timeout_ms must be non-negative" if @websocket_shutdown_timeout_ms < 0
        @configured_drain_timeout = drain_timeout_ms.milliseconds
      rescue error : Exception
        raise ConfigurationError.new(error.message || error.class.to_s)
      end

      app = @app_builder.call(context)
      handlers = [
        ::HTTP::LogHandler.new,
      ] of ::HTTP::Handler
      if context.registered?("http_autoconfig_middleware")
        handlers << context.resolve(
          "http_autoconfig_middleware",
          LF::HTTP::AutoConfigMiddleware
        )
      end
      handlers << LF::HTTP::DI::WebSocketScopeHandler.new(context, "websocket", @websocket_connections)
      handlers << app
      handler = ::HTTP::Server.build_middleware(handlers)
      requests = ConnectionDrainHandler.new(handler, context)
      @requests = requests
      @server = DrainingHttpServer.new(requests)
    end

    def bind : Socket::IPAddress
      raise Error.new("HTTP extension is stopped") if stopped?
      return @address.as(Socket::IPAddress) if @address

      begin
        @address = server.bind_tcp(@configured_host, @configured_port)
      rescue error : Exception
        raise ConfigurationError.new(error.message || error.class.to_s)
      end

      @address.as(Socket::IPAddress)
    end

    def address : Socket::IPAddress
      @address || raise Error.new("HTTP server is not bound")
    end

    def listen : Nil
      bind unless @address
      server.listen
    end

    def stopped? : Bool
      @stop_lock.synchronize { @stop_started }
    end

    def stop : Nil
      loop do
        owner = false
        wait : Channel(Nil)? = nil
        immediate_error : Exception? = nil
        complete = false

        @stop_lock.synchronize do
          if @stop_complete
            immediate_error = @stop_error
            complete = true
          elsif @stop_in_progress
            wait = @stop_done
          elsif error = @stop_error
            if @requests.try(&.drained?)
              @stop_in_progress = true
              @stop_done = Channel(Nil).new
              owner = true
            else
              immediate_error = error
            end
          else
            @stop_started = true
            @stop_in_progress = true
            @stop_done = Channel(Nil).new
            owner = true
          end
        end

        raise immediate_error.as(Exception) if immediate_error
        return if complete

        if wait_channel = wait
          wait_channel.receive?
          next
        end

        if owner
          attempt_error : Exception? = nil
          begin
            deadline = Time.instant + @configured_drain_timeout
            current_server = @server
            current_server.try(&.close) unless current_server.try(&.closed?)
            websocket_budget_ms = Math.min(
              @websocket_shutdown_timeout_ms.to_i64,
              @configured_drain_timeout.total_milliseconds.to_i64
            ).to_i
            @websocket_connections.shutdown(websocket_budget_ms)
            if requests = @requests
              active = requests.drain_until(deadline)
              unless active == 0
                requests.force_close
                raise DrainTimeoutError.new(active)
              end
            end
          rescue error : Exception
            attempt_error = error
          ensure
            done = @stop_lock.synchronize do
              @stop_error = attempt_error
              @stop_complete = attempt_error.nil? || !attempt_error.is_a?(LF::ApplicationExtension::StopIncomplete)
              @stop_in_progress = false
              @stop_done
            end
            done.close
          end

          raise attempt_error.as(Exception) if attempt_error
          return
        end
      end
    end

    private def server : ::HTTP::Server
      @server || raise Error.new("HTTP extension is not configured")
    end
  end

  macro install(runtime, global_owner = nil)
    {{ runtime }}.install(
      LF::HTTP::AutoConfig::Extension.new do |application_context|
        LF::HTTP::App.new do |router|
          {% controllers = LF::HTTP::Controller.includers.sort_by { |controller| controller.name.stringify } %}
          {% for controller in controllers %}
            {{ controller }}.setup_routes(router, application_context, {{ global_owner }})
          {% end %}
          LF::LiveView::AutoConfig.mount(router, application_context, {{ global_owner }})
        end
      end
    )
  end
end

macro finished
  {% for klass in Object.all_subclasses %}
    {% if klass.annotation(LF::AutoConfig::HTTP) %}
      {% unless klass.annotation(LF::Application) %}
        {% raise "@[LF::AutoConfig::HTTP] requires @[LF::Application] on #{klass.name}" %}
      {% end %}

      class {{ klass }}
        def self.run_http : Nil
          runtime = bootstrap

          begin
            extension = LF::HTTP::AutoConfig.install(runtime, {{ klass }})
            Process.on_terminate do |_reason|
              extension.stop
            end
            extension.listen
          ensure
            runtime.shutdown unless runtime.closed?
          end
        end
      end
    {% end %}
  {% end %}
end
