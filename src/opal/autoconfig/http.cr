require "http/server"
require "../../opal"
require "sync/condition_variable"
require "sync/mutex"

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

  class RequestDrainHandler
    include ::HTTP::Handler

    @lock : Sync::Mutex
    @drained : Sync::ConditionVariable
    @accepting = true
    @active_requests = 0

    def initialize
      @lock = Sync::Mutex.new
      @drained = Sync::ConditionVariable.new(@lock)
    end

    def call(context : ::HTTP::Server::Context) : Nil
      accepted = @lock.synchronize do
        if @accepting
          @active_requests += 1
          true
        else
          false
        end
      end

      unless accepted
        context.response.status = ::HTTP::Status::SERVICE_UNAVAILABLE
        context.response.content_type = "text/plain"
        context.response.print "Service Unavailable"
        return
      end

      call_next(context)
    ensure
      if accepted
        @lock.synchronize do
          @active_requests -= 1
          @drained.broadcast if @active_requests == 0
        end
      end
    end

    def stop_accepting : Nil
      @lock.synchronize do
        @accepting = false
      end
    end

    def wait_until_drained : Nil
      @lock.synchronize do
        while @active_requests > 0
          @drained.wait
        end
      end
    end
  end

  class Extension
    include LF::ApplicationExtension

    getter configured_host = "0.0.0.0"
    getter configured_port = 8080

    @server : ::HTTP::Server?
    @address : Socket::IPAddress?
    @stopped = false
    @request_drain = RequestDrainHandler.new

    def initialize(&@app_builder : LF::ApplicationContext -> LF::HTTP::App)
    end

    def configure(context : LF::ApplicationContext) : Nil
      config = context.resolve(LF::ConfigService)

      begin
        @configured_host = config.get("http.host", "0.0.0.0")
        @configured_port = config.get("http.port", 8080)
        unless 0 <= @configured_port <= 65_535
          raise "http.port must be between 0 and 65535"
        end
      rescue error : Exception
        raise ConfigurationError.new(error.message || error.class.to_s)
      end

      app = @app_builder.call(context)
      @server = ::HTTP::Server.new([
        ::HTTP::LogHandler.new,
        @request_drain,
        LF::HTTP::DI::RequestScopeHandler.new(context),
        app,
      ])
    end

    def bind : Socket::IPAddress
      raise Error.new("HTTP extension is stopped") if @stopped
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
      @stopped
    end

    def stop : Nil
      return if @stopped
      @stopped = true
      @request_drain.stop_accepting
      @server.try(&.close)
      @request_drain.wait_until_drained
    end

    private def server : ::HTTP::Server
      @server || raise Error.new("HTTP extension is not configured")
    end
  end

  macro install(runtime)
    {{ runtime }}.install(
      LF::HTTP::AutoConfig::Extension.new do |application_context|
        LF::HTTP::App.new do |router|
          {% controllers = LF::HTTP::Controller.includers.sort_by { |controller| controller.name.stringify } %}
          {% for controller in controllers %}
            {{ controller }}.setup_routes(router, application_context)
          {% end %}
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
            extension = LF::HTTP::AutoConfig.install(runtime)
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
