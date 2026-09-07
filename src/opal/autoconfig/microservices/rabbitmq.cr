require "../../../opal"
require "../../microservices/rabbitmq"

module LF::AutoConfig
  # Enables RabbitMQ-backed message controllers and typed RPC clients for one
  # application. Local service identity is required only when `controllers` is
  # non-empty.
  annotation Microservices
  end
end

module LF::Microservices::AutoConfig
  alias ClientRegistrar = Proc(LF::ApplicationContext, RPCClient, Nil)

  class Error < LF::Microservices::Error
  end

  class ConfigurationError < Error
    def initialize(reason : String, cause : Exception? = nil)
      super("Invalid microservices configuration: #{reason}", cause)
    end
  end

  private struct Configuration
    getter profile : ProtocolProfile
    getter rabbitmq : RabbitMQ::Settings
    getter instance_id : String?
    getter max_pending : Int32
    getter max_replies : Int32

    def initialize(
      @profile : ProtocolProfile,
      @rabbitmq : RabbitMQ::Settings,
      @instance_id : String?,
      max_pending : Int,
      max_replies : Int,
    )
      Microservices.validate_alias(instance_id, "microservices.instance_id") if instance_id
      @max_pending = positive_i32(max_pending, "microservices.client.max_pending")
      @max_replies = positive_i32(max_replies, "microservices.client.max_replies")
    end

    def self.load(config : LF::ConfigService) : self
      transport = config.get("microservices.transport", "rabbitmq")
      unless transport == "rabbitmq"
        raise ConfigurationError.new(
          "microservices.transport must be rabbitmq for this entrypoint",
        )
      end
      instance_id = config.get("microservices.instance_id", "")
      new(
        profile: ProtocolProfile.new(topology: TopologyConfig.from_config(config)),
        rabbitmq: RabbitMQ::Settings.from_config(config),
        instance_id: instance_id.empty? ? nil : instance_id,
        max_pending: config.get("microservices.client.max_pending", 1_024),
        max_replies: config.get("microservices.client.max_replies", 1_024),
      )
    rescue error : ConfigurationError
      raise error
    rescue error : Exception
      raise ConfigurationError.new(error.message || error.class.to_s, error)
    end

    private def positive_i32(value : Int, field : String) : Int32
      unless value > 0 && value <= Int32::MAX
        raise ConfigurationError.new("#{field} must be a positive 32-bit integer")
      end
      value.to_i32
    end
  end

  # Application-owned composition of an optional inbound server runtime and
  # one shared outbound RPC client. All resources participate in the normal
  # ApplicationRuntime quiesce/stop lifecycle.
  @[LF::ApplicationAutoConfiguration(
    enabled_by: LF::AutoConfig::Microservices,
    priority: 50
  )]
  class Extension
    include LF::ApplicationExtension

    getter server_runtime : ServerRuntime?
    getter client_transport : RabbitMQ::ClientTransport?
    getter rpc_client : RPCClient?
    getter? configured = false
    getter? stopped = false

    def initialize(
      @server_session_factory : RabbitMQ::SessionFactory? = nil,
      @client_session_factory : RabbitMQ::SessionFactory? = nil,
    )
    end

    def configure(context : LF::ApplicationContext) : Nil
      {% begin %}
        {% applications = Object.all_subclasses.select { |candidate| candidate.annotation(LF::Application) && candidate.annotation(LF::AutoConfig::Microservices) } %}
        {% if applications.size != 1 %}
          raise ConfigurationError.new("expected exactly one annotated application")
        {% else %}
        {% application = applications.first %}
        {% annotations = application.annotations(LF::AutoConfig::Microservices) %}
        {% if annotations.size != 1 %}
          {% raise "#{application} must declare exactly one @[LF::AutoConfig::Microservices] annotation" %}
        {% end %}
        {% descriptor = annotations.first %}
        {% controllers = descriptor[:controllers] || [] of ASTNode %}
        {% clients = descriptor[:clients] || [] of ASTNode %}
        {% unless controllers.is_a?(ArrayLiteral) || controllers.is_a?(TupleLiteral) %}
          {% raise "Microservices controllers on #{application} must be an array or tuple of types" %}
        {% end %}
        {% unless clients.is_a?(ArrayLiteral) || clients.is_a?(TupleLiteral) %}
          {% raise "Microservices clients on #{application} must be an array or tuple of types" %}
        {% end %}
        {% if controllers.empty? && clients.empty? %}
          {% raise "Microservices autoconfiguration on #{application} requires controllers or clients" %}
        {% end %}

        {% if controllers.empty? %}
          service = nil.as(ServiceIdentity?)
          registry_builder = nil.as(RegistryBuilder?)
        {% else %}
          {% namespace = descriptor[:namespace] %}
          {% service_name = descriptor[:service] %}
          {% contract_version = descriptor[:contract_version] %}
          {% unless namespace.is_a?(StringLiteral) && service_name.is_a?(StringLiteral) %}
            {% raise "Microservices namespace and service on #{application} must be string literals" %}
          {% end %}
          {% unless contract_version.is_a?(NumberLiteral) %}
            {% raise "Microservices contract_version on #{application} must be an integer literal" %}
          {% end %}
          service = ServiceIdentity.new({{ namespace }}, {{ service_name }}, {{ contract_version }})
          registry_builder = RegistryBuilder.new do |application_context|
            LF::Microservices.compile_executable_handlers(
              service,
              application_context,
              {% for controller in controllers %}
                {{ controller }},
              {% end %}
            )
          end
        {% end %}

        {% for client in clients %}
          {% client_type = client.resolve %}
          {% unless client_type.ancestors.includes?(LF::Microservices::TypedServiceClient) %}
            {% raise "Invalid typed microservices client #{client_type} on #{application}: expected LF::Microservices::TypedServiceClient" %}
          {% end %}
        {% end %}

        registrar = ClientRegistrar.new do |application_context, rpc|
          {% for client, index in clients %}
            application_context.register_bean(
              name: {{ "__lf_microservices_client_#{index}_#{client.resolve.name}" }},
              type: {{ client.resolve }},
            ) do |scope|
              {{ client.resolve }}.new(scope.resolve(RPCClient))
            end
          {% end %}
        end

          configure_application(
            context,
            service,
            registry_builder,
            {{ !clients.empty? }},
            registrar,
          )
        {% end %}
      {% end %}
    end

    def quiesce(context : LF::ShutdownContext) : Nil
      @server_runtime.try(&.quiesce(context))
    end

    def stop : Nil
      return if stopped?

      first_error : Exception? = nil
      begin
        @server_runtime.try do |runtime|
          runtime.stop unless runtime.stopped?
        end
      rescue error : Exception
        first_error = error
      end
      begin
        if client = @rpc_client
          client.close unless client.closed?
        elsif transport = @client_transport
          transport.close unless transport.status.closed?
        end
      rescue error : Exception
        first_error ||= error
      end

      raise first_error.as(Exception) if first_error
      @stopped = true
    end

    private def configure_application(
      context : LF::ApplicationContext,
      service : ServiceIdentity?,
      registry_builder : RegistryBuilder?,
      has_clients : Bool,
      registrar : ClientRegistrar,
    ) : Nil
      raise ConfigurationError.new("extension is already configured") if configured?
      configuration = Configuration.load(context.resolve(LF::ConfigService))

      if has_clients
        transport = RabbitMQ::ClientTransport.new(
          configuration.rabbitmq,
          configuration.profile,
          session_factory: @client_session_factory,
          max_pending: configuration.max_pending,
          max_replies: configuration.max_replies,
        )
        @client_transport = transport
        transport.start
        client = RPCClient.new(
          transport,
          JSONCodec.new(configuration.profile),
          max_pending: configuration.max_pending,
        )
        @rpc_client = client
        context.register_bean(name: "rpc_client", type: RPCClient) { |_scope| client }
        context.resolve("rpc_client", RPCClient)
        registrar.call(context, client)
      end

      # Outbound dependencies must be registered before inbound intake starts:
      # a message controller may inject one of the typed clients above.
      if builder = registry_builder
        local_service = service || raise ConfigurationError.new(
          "local service identity is required when controllers are configured",
        )
        transport = RabbitMQ::ServerTransport.new(
          local_service,
          configuration.rabbitmq,
          configuration.profile,
          session_factory: @server_session_factory,
        )
        runtime = ServerRuntime.new(
          local_service,
          transport,
          JSONCodec.new(configuration.profile),
          instance_id: configuration.instance_id,
          &builder
        )
        @server_runtime = runtime
        runtime.configure(context)
      end

      @configured = true
    end
  end
end

macro finished
  {% for klass in Object.all_subclasses %}
    {% if klass.annotation(LF::AutoConfig::Microservices) %}
      {% unless klass.annotation(LF::Application) %}
        {% raise "@[LF::AutoConfig::Microservices] requires @[LF::Application] on #{klass.name}" %}
      {% end %}

      class {{ klass }}
        # Bootstraps the application with its RabbitMQ microservices extension.
        # This is an alias for `bootstrap`; the explicit name is useful in
        # applications that resolve outbound typed clients before starting an
        # HTTP or other process loop.
        def self.bootstrap_microservice : LF::ApplicationRuntime
          bootstrap
        end

        # Runs a message-only process until SIGINT or SIGTERM. Applications
        # combining this marker with HTTP should use `run_http`, which shares
        # the same automatically installed extension.
        def self.run_microservice : Nil
          runtime = bootstrap_microservice
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
