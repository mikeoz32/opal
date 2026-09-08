module LF::Microservices
  alias StreamHandlerInvoker = Proc(LF::DI::Container, ExecutionContext, JSON::Any, Nil)

  class CompiledStreamHandler
    getter topology : StreamTopologyDefinition
    getter topology_type : String
    getter subscription : String
    getter identity : EventIdentity
    getter handler : String
    getter action : String
    getter invoker : StreamHandlerInvoker

    def initialize(
      @topology : StreamTopologyDefinition,
      @topology_type : String,
      @subscription : String,
      @identity : EventIdentity,
      @handler : String,
      @action : String,
      @invoker : StreamHandlerInvoker,
    )
      Microservices.validate_alias(subscription, "stream subscription")
    end

    def invoke(scope : LF::DI::Container, context : ExecutionContext, payload : JSON::Any) : Nil
      invoker.call(scope, context, payload)
    end
  end

  class StreamSubscriptionPlan
    getter topology : StreamTopologyDefinition
    getter topology_type : String
    getter subscription : String
    getter handlers : Hash(String, CompiledStreamHandler)

    def initialize(
      @topology : StreamTopologyDefinition,
      @topology_type : String,
      @subscription : String,
    )
      @handlers = {} of String => CompiledStreamHandler
    end

    def add(handler : CompiledStreamHandler) : Nil
      unless handler.topology == topology && handler.topology_type == topology_type
        raise StreamConfigurationError.new(
          "subscription #{subscription} mixes incompatible stream topologies",
        )
      end
      route = identity_key(handler.identity)
      if existing = handlers[route]?
        raise StreamConfigurationError.new(
          "duplicate stream handler for #{route} in #{subscription}: #{existing.handler} and #{handler.handler}",
        )
      end
      handlers[route] = handler
    end

    def handler(identity : EventIdentity) : CompiledStreamHandler?
      handlers[identity_key(identity)]?
    end

    def knows_event?(identity : EventIdentity) : Bool
      handlers.values.any? do |handler|
        handler.identity.source == identity.source && handler.identity.event == identity.event
      end
    end

    private def identity_key(identity : EventIdentity) : String
      "#{identity.source.label}.#{identity.routing_key}"
    end
  end

  class StreamHandlerRegistry
    @subscriptions = {} of String => StreamSubscriptionPlan
    @sealed = false

    def add(handler : CompiledStreamHandler) : Nil
      raise StreamConfigurationError.new("stream handler registry is sealed") if sealed?
      key = subscription_key(handler.topology.name, handler.subscription)
      plan = @subscriptions[key] ||= StreamSubscriptionPlan.new(
        handler.topology,
        handler.topology_type,
        handler.subscription,
      )
      plan.add(handler)
    end

    def seal : self
      @sealed = true
      self
    end

    def sealed? : Bool
      @sealed
    end

    def subscriptions : Array(StreamSubscriptionPlan)
      @subscriptions.values
    end

    private def subscription_key(topology : String, subscription : String) : String
      "#{topology}:#{subscription}"
    end
  end

  # Compiles a closed list of stream handler classes into typed invokers.
  macro compile_stream_handlers(*handler_nodes)
    {% stream_routes = [] of ASTNode %}
    %registry = LF::Microservices::StreamHandlerRegistry.new

    {% for handler_node in handler_nodes %}
      {% handler = handler_node.resolve %}
      {% unless handler.ancestors.includes?(LF::Microservices::StreamProjection) %}
        {% raise "Invalid stream handler #{handler}: expected LF::Microservices::StreamProjection" %}
      {% end %}
      {% annotations = handler.annotations(LF::Microservices::StreamHandler) %}
      {% if annotations.size != 1 %}
        {% raise "#{handler} must declare exactly one @[LF::Microservices::StreamHandler] annotation" %}
      {% end %}
      {% descriptor = annotations.first %}
      {% topology_node = descriptor[:topology] %}
      {% subscription = descriptor[:subscription] %}
      {% unless topology_node.is_a?(Path) || topology_node.is_a?(Generic) %}
        {% raise "Stream handler topology on #{handler} must be a type" %}
      {% end %}
      {% topology = topology_node.resolve %}
      {% unless topology.ancestors.includes?(LF::Microservices::StreamTopology) %}
        {% raise "Stream handler topology #{topology} must include LF::Microservices::StreamTopology" %}
      {% end %}
      {% unless subscription.is_a?(StringLiteral) %}
        {% raise "Stream handler subscription on #{handler} must be a string literal" %}
      {% end %}
      {% methods = handler.methods.select { |method| method.name.stringify == "handle" } %}
      {% if methods.size != 1 %}
        {% raise "#{handler} must define exactly one #handle method" %}
      {% end %}
      {% method = methods.first %}
      {% unless method.args.size == 2 %}
        {% raise "#{handler}#handle must accept event and LF::Microservices::StreamContext" %}
      {% end %}
      {% event_argument = method.args[0] %}
      {% context_argument = method.args[1] %}
      {% unless event_argument.restriction %}
        {% raise "#{handler}#handle event argument must have a concrete type" %}
      {% end %}
      {% event_type = event_argument.restriction.resolve %}
      {% unless event_type.ancestors.includes?(LF::Microservices::StreamEvent) %}
        {% raise "#{handler}#handle event must include LF::Microservices::StreamEvent" %}
      {% end %}
      {% event_descriptor = event_type.annotation(LF::Microservices::StreamEventContract) %}
      {% namespace = event_descriptor[:namespace] %}
      {% service_name = event_descriptor[:service] %}
      {% contract_version = event_descriptor[:contract_version] %}
      {% event_name = event_descriptor[:event] %}
      {% schema_version = event_descriptor[:schema_version] %}
      {% route = topology.name.stringify + ":" + subscription + ":" + namespace + "." + service_name + ".v" + contract_version.stringify + "." + event_name + ".v" + schema_version.stringify %}
      {% if stream_routes.includes?(route) %}
        {% raise "Duplicate stream handler route #{route} in compiled stream handlers" %}
      {% end %}
      {% stream_routes << route %}
      {% unless context_argument.restriction && context_argument.restriction.resolve == LF::Microservices::ExecutionContext %}
        {% raise "#{handler}#handle context must be LF::Microservices::StreamContext" %}
      {% end %}
      {% result_type = method.return_type %}
      {% unless result_type && result_type.resolve == Nil %}
        {% raise "#{handler}#handle must return Nil" %}
      {% end %}

      {% handler_guards = [] of ASTNode %}
      {% handler_pipes = [] of ASTNode %}
      {% handler_interceptors = [] of ASTNode %}
      {% handler_filters = [] of ASTNode %}
      {% action_filters = [] of ASTNode %}
      {% argument_pipes = [] of ASTNode %}
      {% for policy_annotation in handler.annotations(LF::Microservices::UseGuards) %}
        {% for policy in policy_annotation.args %}
          {% handler_guards << policy %}
        {% end %}
      {% end %}
      {% for policy_annotation in handler.annotations(LF::Microservices::UsePipes) %}
        {% for policy in policy_annotation.args %}
          {% handler_pipes << policy %}
        {% end %}
      {% end %}
      {% for policy_annotation in handler.annotations(LF::Microservices::UseInterceptors) %}
        {% for policy in policy_annotation.args %}
          {% handler_interceptors << policy %}
        {% end %}
      {% end %}
      {% for policy_annotation in handler.annotations(LF::Microservices::UseFilters) %}
        {% for policy in policy_annotation.args %}
          {% handler_filters << policy %}
        {% end %}
      {% end %}
      {% for policy_annotation in method.annotations(LF::Microservices::UseGuards) %}
        {% for policy in policy_annotation.args %}
          {% handler_guards << policy %}
        {% end %}
      {% end %}
      {% for policy_annotation in method.annotations(LF::Microservices::UsePipes) %}
        {% for policy in policy_annotation.args %}
          {% handler_pipes << policy %}
        {% end %}
      {% end %}
      {% for policy_annotation in method.annotations(LF::Microservices::UseInterceptors) %}
        {% for policy in policy_annotation.args %}
          {% handler_interceptors << policy %}
        {% end %}
      {% end %}
      {% for policy_annotation in method.annotations(LF::Microservices::UseFilters) %}
        {% for policy in policy_annotation.args %}
          {% action_filters << policy %}
        {% end %}
      {% end %}
      {% for policy_annotation in event_argument.annotations(LF::Microservices::UsePipes) %}
        {% for policy in policy_annotation.args %}
          {% argument_pipes << policy %}
        {% end %}
      {% end %}

      {% for policy in handler_guards %}
        {% unless policy.resolve.ancestors.includes?(LF::Microservices::Guard) %}
          {% raise "Invalid stream guard #{policy} on #{handler}" %}
        {% end %}
      {% end %}
      {% for policy in handler_pipes + argument_pipes %}
        {% unless policy.resolve.ancestors.includes?(LF::Microservices::Pipe) %}
          {% raise "Invalid stream pipe #{policy} on #{handler}" %}
        {% end %}
      {% end %}
      {% for policy in handler_interceptors %}
        {% unless policy.resolve.ancestors.includes?(LF::Microservices::Interceptor) %}
          {% raise "Invalid stream interceptor #{policy} on #{handler}" %}
        {% end %}
      {% end %}
      {% for policy in action_filters + handler_filters %}
        {% unless policy.resolve.ancestors.includes?(LF::Microservices::Filter) %}
          {% raise "Invalid stream filter #{policy} on #{handler}" %}
        {% end %}
      {% end %}

      %registry.add(LF::Microservices::CompiledStreamHandler.new(
        topology: {{ topology }}.stream_definition,
        topology_type: {{ topology.name.stringify }},
        subscription: {{ subscription }},
        identity: {{ event_type }}.stream_event_identity,
        handler: {{ handler.name.stringify }},
        action: "handle",
        invoker: LF::Microservices::StreamHandlerInvoker.new do |scope, execution_context, raw_payload|
          filters = [] of LF::Microservices::Filter
          {% for policy in action_filters + handler_filters %}
            filters << scope.resolve({{ policy }}).as(LF::Microservices::Filter)
          {% end %}
          begin
            guards = [] of LF::Microservices::Guard
            {% for policy in handler_guards %}
              guards << scope.resolve({{ policy }}).as(LF::Microservices::Guard)
            {% end %}
            unless LF::Microservices::ExecutionPipeline.authorized?(execution_context, guards)
              raise LF::Microservices::MessageAuthorizationError.new("message guard denied stream execution")
            end

            pipes = [] of LF::Microservices::Pipe
            {% for policy in handler_pipes + argument_pipes %}
              pipes << scope.resolve({{ policy }}).as(LF::Microservices::Pipe)
            {% end %}
            transformed_payload = LF::Microservices::ExecutionPipeline.apply_pipes(
              raw_payload,
              LF::Microservices::ArgumentMetadata.new(
                {{ event_argument.name.stringify }},
                {{ event_type.name.stringify }},
                LF::Microservices::ArgumentSource::Payload,
              ),
              execution_context,
              pipes,
            )
            typed_event = {{ event_type }}.from_json(transformed_payload.to_json)

            interceptors = [] of LF::Microservices::Interceptor
            {% for policy in handler_interceptors %}
              interceptors << scope.resolve({{ policy }}).as(LF::Microservices::Interceptor)
            {% end %}
            LF::Microservices::ExecutionPipeline.intercept(execution_context, interceptors) do
              scope.resolve({{ handler }}).handle(typed_event, execution_context)
              JSON::Any.new(nil)
            end
          rescue exception : Exception
            unless LF::Microservices::ExecutionPipeline.catch(
              exception,
              execution_context,
              filters,
            )
              raise exception
            end
          end
          nil
        end,
      ))
    {% end %}

    %registry.seal
  end
end
