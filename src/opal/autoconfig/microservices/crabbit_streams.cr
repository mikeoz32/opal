require "../../../opal"
require "../../microservices/crabbit_streams"

module LF::AutoConfig
  # Enables typed RabbitMQ Streams publishers and projection handlers backed
  # by Crabbit. `topologies` and `handlers` are explicit closed type lists.
  annotation CrabbitStreams
  end
end

module LF::Microservices::CrabbitStreamsAutoConfig
  alias EnvironmentFactory = Proc(String, ::Crabbit::Environment)

  private struct Configuration
    getter uri : String
    getter producer_name : String
    getter profile : ProtocolProfile
    getter runtime : StreamRuntimeSettings

    def initialize(
      @uri : String,
      @producer_name : String,
      @profile : ProtocolProfile,
      @runtime : StreamRuntimeSettings,
    )
      raise StreamConfigurationError.new("microservices.streams.url must not be empty") if uri.empty?
      raise StreamConfigurationError.new("microservices.streams.producer_name must not be empty") if producer_name.empty?
    end

    def self.load(config : LF::ConfigService) : self
      new(
        uri: config.get(
          "microservices.streams.url",
          "rabbitmq-stream://guest:guest@localhost:5552/%2f",
        ),
        producer_name: config.get("microservices.streams.producer_name", "opal"),
        profile: ProtocolProfile.new(topology: TopologyConfig.from_config(config)),
        runtime: StreamRuntimeSettings.new(
          create_topology: config.get("microservices.streams.create_topology", false),
          initial_offset: initial_offset(config),
          initial_credit: positive_u16(config.get("microservices.streams.initial_credit", 10), "initial_credit"),
          buffer_size: config.get("microservices.streams.buffer_size", 1_024),
          concurrency: config.get("microservices.streams.concurrency", 1),
          retry_policy: StreamRetryPolicy.new(
            max_attempts: config.get("microservices.streams.retry.max_attempts", 5),
            initial_delay: config.get("microservices.streams.retry.initial_delay_ms", 250).milliseconds,
            max_delay: config.get("microservices.streams.retry.max_delay_ms", 10_000).milliseconds,
          ),
          topology_refresh: config.get("microservices.streams.topology_refresh_ms", 30_000).milliseconds,
          single_active_consumer: config.get("microservices.streams.single_active_consumer", true),
        ),
      )
    rescue error : StreamError
      raise error
    rescue error : Exception
      raise StreamConfigurationError.new(
        "invalid Crabbit Streams configuration: #{error.message || error.class}",
        error,
      )
    end

    private def self.initial_offset(config : LF::ConfigService) : ::Crabbit::OffsetSpecification
      case value = config.get("microservices.streams.initial_offset", "first")
      when "first"
        ::Crabbit::OffsetSpecification.first
      when "next"
        ::Crabbit::OffsetSpecification.next
      when "last"
        ::Crabbit::OffsetSpecification.last
      when "timestamp"
        milliseconds = config.get("microservices.streams.initial_timestamp_ms", 0_i64)
        raise StreamConfigurationError.new("initial_timestamp_ms must be positive") unless milliseconds > 0
        ::Crabbit::OffsetSpecification.timestamp(milliseconds)
      else
        raise StreamConfigurationError.new(
          "microservices.streams.initial_offset must be first, next, last, or timestamp; got #{value.inspect}",
        )
      end
    end

    private def self.positive_u16(value : Int, field : String) : UInt16
      unless value > 0 && value <= UInt16::MAX
        raise StreamConfigurationError.new("microservices.streams.#{field} must be a positive UInt16")
      end
      value.to_u16
    end
  end

  @[LF::ApplicationAutoConfiguration(
    enabled_by: LF::AutoConfig::CrabbitStreams,
    priority: 45
  )]
  class Extension
    include LF::ApplicationExtension

    getter environment : ::Crabbit::Environment?
    getter publisher : StreamPublisher?
    getter runtime : StreamHandlerRuntime?
    getter? configured = false
    getter? stopped = false

    def initialize(
      @environment_factory : EnvironmentFactory = ->(uri : String) { ::Crabbit::Environment.connect(uri) },
    )
    end

    def configure(context : LF::ApplicationContext) : Nil
      raise StreamConfigurationError.new("Crabbit Streams extension is already configured") if configured?
      configuration = Configuration.load(context.resolve(LF::ConfigService))

      {% begin %}
        {% applications = Object.all_subclasses.select { |candidate| candidate.annotation(LF::Application) && candidate.annotation(LF::AutoConfig::CrabbitStreams) } %}
        {% if applications.size != 1 %}
          raise LF::Microservices::StreamConfigurationError.new("expected exactly one Crabbit Streams application")
        {% else %}
          {% application = applications.first %}
          {% annotations = application.annotations(LF::AutoConfig::CrabbitStreams) %}
          {% if annotations.size != 1 %}
            {% raise "#{application} must declare exactly one @[LF::AutoConfig::CrabbitStreams] annotation" %}
          {% end %}
          {% descriptor = annotations.first %}
          {% topologies = descriptor[:topologies] || [] of ASTNode %}
          {% handlers = descriptor[:handlers] || [] of ASTNode %}
          {% unless topologies.is_a?(ArrayLiteral) || topologies.is_a?(TupleLiteral) %}
            {% raise "Crabbit Streams topologies on #{application} must be an array or tuple of types" %}
          {% end %}
          {% unless handlers.is_a?(ArrayLiteral) || handlers.is_a?(TupleLiteral) %}
            {% raise "Crabbit Streams handlers on #{application} must be an array or tuple of types" %}
          {% end %}
          {% if topologies.empty? %}
            {% raise "Crabbit Streams autoconfiguration on #{application} requires at least one topology" %}
          {% end %}
          {% for topology_node in topologies %}
            {% topology = topology_node.resolve %}
            {% unless topology.ancestors.includes?(LF::Microservices::StreamTopology) %}
              {% raise "Invalid stream topology #{topology}: expected LF::Microservices::StreamTopology" %}
            {% end %}
          {% end %}

          registry = LF::Microservices.compile_stream_handlers(
            {% for handler in handlers %}
              {{ handler }},
            {% end %}
          )
          declared_topologies = [
            {% for topology_node in topologies %}
              {{ topology_node.resolve }}.stream_definition,
            {% end %}
          ] of LF::Microservices::StreamTopologyDefinition

          configure_application(context, configuration, registry, declared_topologies)
        {% end %}
      {% end %}
    end

    def quiesce(context : LF::ShutdownContext) : Nil
      @runtime.try(&.quiesce(context))
      if current = @publisher
        raise StreamDrainTimeoutError.new unless current.drain(context.deadline)
      end
    end

    def stop : Nil
      return if stopped?
      first_error = nil.as(Exception?)
      begin
        @runtime.try(&.close)
      rescue error : Exception
        first_error = error
      end
      begin
        @publisher.try(&.close)
      rescue error : Exception
        first_error ||= error
      end
      begin
        @environment.try(&.close)
      rescue error : Exception
        first_error ||= error
      end
      raise first_error.as(Exception) if first_error
      @stopped = true
    end

    private def configure_application(
      context : LF::ApplicationContext,
      configuration : Configuration,
      registry : StreamHandlerRegistry,
      topologies : Array(StreamTopologyDefinition),
    ) : Nil
      environment = @environment_factory.call(configuration.uri)
      @environment = environment
      publisher = StreamPublisher.new(
        environment,
        configuration.producer_name,
        JSONCodec.new(configuration.profile),
      )
      @publisher = publisher
      context.register_bean(name: "stream_publisher", type: StreamPublisher) { |_scope| publisher }
      context.resolve("stream_publisher", StreamPublisher)

      runtime = StreamHandlerRuntime.new(
        environment,
        registry,
        configuration.runtime,
        JSONCodec.new(configuration.profile),
        topologies: topologies,
      )
      @runtime = runtime
      context.register_bean(name: "stream_handler_runtime", type: StreamHandlerRuntime) { |_scope| runtime }
      context.resolve("stream_handler_runtime", StreamHandlerRuntime)
      runtime.configure(context)
      @configured = true
    end
  end
end

macro finished
  {% for klass in Object.all_subclasses %}
    {% if klass.annotation(LF::AutoConfig::CrabbitStreams) %}
      {% unless klass.annotation(LF::Application) %}
        {% raise "@[LF::AutoConfig::CrabbitStreams] requires @[LF::Application] on #{klass.name}" %}
      {% end %}

      class {{ klass }}
        def self.bootstrap_stream_worker : LF::ApplicationRuntime
          bootstrap
        end

        def self.run_stream_worker : Nil
          runtime = bootstrap_stream_worker
          terminating = Channel(Nil).new
          Process.on_terminate { |_reason| terminating.close }
          terminating.receive?
        ensure
          runtime.try do |active_runtime|
            active_runtime.shutdown unless active_runtime.closed?
          end
        end
      end
    {% end %}
  {% end %}
end
