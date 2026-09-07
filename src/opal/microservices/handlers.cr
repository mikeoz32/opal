module LF::Microservices
  alias HandlerInvoker = Proc(LF::DI::Container, ExecutionContext, JSON::Any, JSON::Any)

  annotation RPC
  end

  annotation Event
  end

  # Marks a class as an explicit message-controller candidate. Controllers are
  # still passed to `compile_handlers`; Opal never scans files or namespaces.
  module MessageController
  end

  struct PolicyPlan
    def initialize(
      guards : Array(String) = [] of String,
      pipes : Array(String) = [] of String,
      interceptors : Array(String) = [] of String,
      filters : Array(String) = [] of String,
    )
      @guards = guards.dup
      @pipes = pipes.dup
      @interceptors = interceptors.dup
      @filters = filters.dup
    end

    def guards : Array(String)
      @guards.dup
    end

    def pipes : Array(String)
      @pipes.dup
    end

    def interceptors : Array(String)
      @interceptors.dup
    end

    def filters : Array(String)
      @filters.dup
    end
  end

  struct RPCHandlerPlan
    getter target : RPCTarget
    getter controller : String
    getter action : String
    getter request_type : String
    getter response_type : String
    getter policies : PolicyPlan
    @invoker : HandlerInvoker?

    def initialize(
      @target : RPCTarget,
      @controller : String,
      @action : String,
      @request_type : String,
      @response_type : String,
      @policies : PolicyPlan = PolicyPlan.new,
      @invoker : HandlerInvoker? = nil,
    )
      validate_handler_names
    end

    def invoke(scope : LF::DI::Container, context : ExecutionContext, payload : JSON::Any) : JSON::Any
      invoker = @invoker || raise HandlerCompilationError.new(
        "RPC handler plan is metadata-only: #{target.routing_key}"
      )
      invoker.call(scope, context, payload)
    end

    private def validate_handler_names : Nil
      raise HandlerCompilationError.new("controller must not be empty") if controller.empty?
      raise HandlerCompilationError.new("action must not be empty") if action.empty?
      raise HandlerCompilationError.new("request_type must not be empty") if request_type.empty?
      raise HandlerCompilationError.new("response_type must not be empty") if response_type.empty?
    end
  end

  struct EventHandlerPlan
    getter identity : EventIdentity
    getter controller : String
    getter action : String
    getter payload_type : String
    getter subscription : String
    getter mode : EventDispatchMode
    getter reliable : Bool?
    getter policies : PolicyPlan
    @invoker : HandlerInvoker?

    def initialize(
      @identity : EventIdentity,
      @controller : String,
      @action : String,
      @payload_type : String,
      @subscription : String,
      @mode : EventDispatchMode,
      @reliable : Bool? = nil,
      @policies : PolicyPlan = PolicyPlan.new,
      @invoker : HandlerInvoker? = nil,
    )
      Microservices.validate_alias(subscription, "subscription")
      raise HandlerCompilationError.new("controller must not be empty") if controller.empty?
      raise HandlerCompilationError.new("action must not be empty") if action.empty?
      raise HandlerCompilationError.new("payload_type must not be empty") if payload_type.empty?
    end

    def invoke(scope : LF::DI::Container, context : ExecutionContext, payload : JSON::Any) : JSON::Any
      invoker = @invoker || raise HandlerCompilationError.new(
        "event handler plan is metadata-only: #{route_key}"
      )
      invoker.call(scope, context, payload)
    end

    def route_key : String
      "#{identity.source.label}.#{identity.routing_key}.#{subscription}"
    end
  end

  class HandlerRegistry
    @rpc_handlers = {} of String => RPCHandlerPlan
    @event_handlers = {} of String => EventHandlerPlan
    @sealed = false

    def add(plan : RPCHandlerPlan) : Nil
      ensure_mutable
      route = plan.target.routing_key
      if @rpc_handlers.has_key?(route)
        raise HandlerCompilationError.new("duplicate RPC route: #{route}")
      end
      @rpc_handlers[route] = plan
    end

    def add(plan : EventHandlerPlan) : Nil
      ensure_mutable
      route = plan.route_key
      if @event_handlers.has_key?(route)
        raise HandlerCompilationError.new("duplicate event subscription route: #{route}")
      end
      @event_handlers[route] = plan
    end

    def seal : self
      @sealed = true
      self
    end

    def sealed? : Bool
      @sealed
    end

    def rpc_handlers : Array(RPCHandlerPlan)
      @rpc_handlers.values
    end

    def event_handlers : Array(EventHandlerPlan)
      @event_handlers.values
    end

    def rpc(routing_key : String) : RPCHandlerPlan?
      @rpc_handlers[routing_key]?
    end

    def event(route_key : String) : EventHandlerPlan?
      @event_handlers[route_key]?
    end

    private def ensure_mutable : Nil
      if sealed?
        raise HandlerCompilationError.new("handler registry is sealed")
      end
    end
  end

  # Compiles a closed list of message controller types into immutable runtime
  # metadata. The macro validates annotations, signatures, DTOs, policy types,
  # and duplicate routes while compiling the application.
  macro compile_handlers(service, *controller_nodes)
    {% rpc_aliases = [] of ASTNode %}
    {% event_routes = [] of ASTNode %}
    %registry = LF::Microservices::HandlerRegistry.new

    {% for controller_node in controller_nodes %}
      {% controller = controller_node.resolve %}
      {% unless controller.ancestors.includes?(LF::Microservices::MessageController) %}
        {% raise "Invalid message controller #{controller}: expected LF::Microservices::MessageController" %}
      {% end %}

      {% controller_guards = [] of ASTNode %}
      {% controller_pipes = [] of ASTNode %}
      {% controller_interceptors = [] of ASTNode %}
      {% controller_filters = [] of ASTNode %}
      {% for policy_annotation in controller.annotations(LF::Microservices::UseGuards) %}
        {% for policy in policy_annotation.args %}
          {% unless policy.resolve.ancestors.includes?(LF::Microservices::Guard) %}
            {% raise "Invalid guard #{policy} on #{controller}: expected LF::Microservices::Guard" %}
          {% end %}
          {% controller_guards << policy %}
        {% end %}
      {% end %}
      {% for policy_annotation in controller.annotations(LF::Microservices::UsePipes) %}
        {% for policy in policy_annotation.args %}
          {% unless policy.resolve.ancestors.includes?(LF::Microservices::Pipe) %}
            {% raise "Invalid pipe #{policy} on #{controller}: expected LF::Microservices::Pipe" %}
          {% end %}
          {% controller_pipes << policy %}
        {% end %}
      {% end %}
      {% for policy_annotation in controller.annotations(LF::Microservices::UseInterceptors) %}
        {% for policy in policy_annotation.args %}
          {% unless policy.resolve.ancestors.includes?(LF::Microservices::Interceptor) %}
            {% raise "Invalid interceptor #{policy} on #{controller}: expected LF::Microservices::Interceptor" %}
          {% end %}
          {% controller_interceptors << policy %}
        {% end %}
      {% end %}
      {% for policy_annotation in controller.annotations(LF::Microservices::UseFilters) %}
        {% for policy in policy_annotation.args %}
          {% unless policy.resolve.ancestors.includes?(LF::Microservices::Filter) %}
            {% raise "Invalid filter #{policy} on #{controller}: expected LF::Microservices::Filter" %}
          {% end %}
          {% controller_filters << policy %}
        {% end %}
      {% end %}

      {% for method in controller.methods.sort_by(&.line_number) %}
        {% rpc_annotations = method.annotations(LF::Microservices::RPC) %}
        {% event_annotations = method.annotations(LF::Microservices::Event) %}
        {% if rpc_annotations.size > 0 && event_annotations.size > 0 %}
          {% raise "Invalid message handler #{controller}##{method.name}: cannot be both RPC and event" %}
        {% end %}
        {% for rpc_annotation in rpc_annotations %}
          {% rpc_method = rpc_annotation[:method] || rpc_annotation[0] %}
          {% schema_version = rpc_annotation[:schema_version] %}
          {% unless rpc_method && rpc_method.is_a?(StringLiteral) %}
            {% raise "Invalid RPC method on #{controller}##{method.name}: expected string literal" %}
          {% end %}
          {% unless schema_version && schema_version.is_a?(NumberLiteral) %}
            {% raise "Invalid RPC schema_version on #{controller}##{method.name}: expected integer literal" %}
          {% end %}
          {% if rpc_aliases.includes?(rpc_method) %}
            {% raise "Duplicate RPC method #{rpc_method} in compiled message controllers" %}
          {% end %}
          {% rpc_aliases << rpc_method %}
          {% unless method.args.size == 1 %}
            {% raise "Invalid RPC handler #{controller}##{method.name}: expected exactly one typed payload argument" %}
          {% end %}
          {% payload_argument = method.args[0] %}
          {% if payload_argument.restriction.is_a?(Nop) %}
            {% raise "Invalid RPC payload #{controller}##{method.name}: expected an explicit JSON::Serializable type" %}
          {% end %}
          {% payload_type = payload_argument.restriction.resolve %}
          {% unless payload_type.ancestors.includes?(JSON::Serializable) %}
            {% raise "Invalid RPC payload #{controller}##{method.name}: #{payload_type} must include JSON::Serializable" %}
          {% end %}
          {% if method.return_type.is_a?(Nop) %}
            {% raise "Invalid RPC result #{controller}##{method.name}: expected an explicit JSON::Serializable or Nil type" %}
          {% end %}
          {% result_type = method.return_type.resolve %}
          {% unless result_type == Nil || result_type.ancestors.includes?(JSON::Serializable) %}
            {% raise "Invalid RPC result #{controller}##{method.name}: #{result_type} must include JSON::Serializable or be Nil" %}
          {% end %}

          {% action_guards = [] of ASTNode %}
          {% action_pipes = [] of ASTNode %}
          {% action_interceptors = [] of ASTNode %}
          {% action_filters = [] of ASTNode %}
          {% for policy_annotation in method.annotations(LF::Microservices::UseGuards) %}
            {% for policy in policy_annotation.args %}
              {% unless policy.resolve.ancestors.includes?(LF::Microservices::Guard) %}
                {% raise "Invalid guard #{policy} on #{controller}##{method.name}: expected LF::Microservices::Guard" %}
              {% end %}
              {% action_guards << policy %}
            {% end %}
          {% end %}
          {% for policy_annotation in method.annotations(LF::Microservices::UsePipes) %}
            {% for policy in policy_annotation.args %}
              {% unless policy.resolve.ancestors.includes?(LF::Microservices::Pipe) %}
                {% raise "Invalid pipe #{policy} on #{controller}##{method.name}: expected LF::Microservices::Pipe" %}
              {% end %}
              {% action_pipes << policy %}
            {% end %}
          {% end %}
          {% for policy_annotation in method.annotations(LF::Microservices::UseInterceptors) %}
            {% for policy in policy_annotation.args %}
              {% unless policy.resolve.ancestors.includes?(LF::Microservices::Interceptor) %}
                {% raise "Invalid interceptor #{policy} on #{controller}##{method.name}: expected LF::Microservices::Interceptor" %}
              {% end %}
              {% action_interceptors << policy %}
            {% end %}
          {% end %}
          {% for policy_annotation in method.annotations(LF::Microservices::UseFilters) %}
            {% for policy in policy_annotation.args %}
              {% unless policy.resolve.ancestors.includes?(LF::Microservices::Filter) %}
                {% raise "Invalid filter #{policy} on #{controller}##{method.name}: expected LF::Microservices::Filter" %}
              {% end %}
              {% action_filters << policy %}
            {% end %}
          {% end %}
          {% argument_pipes = [] of ASTNode %}
          {% for pipe_annotation in payload_argument.annotations(LF::Microservices::UsePipes) %}
            {% for policy in pipe_annotation.args %}
              {% unless policy.resolve.ancestors.includes?(LF::Microservices::Pipe) %}
                {% raise "Invalid pipe #{policy} on payload #{controller}##{method.name}: expected LF::Microservices::Pipe" %}
              {% end %}
              {% argument_pipes << policy %}
            {% end %}
          {% end %}

          %registry.add(LF::Microservices::RPCHandlerPlan.new(
            target: LF::Microservices::RPCTarget.new({{ service }}, {{ rpc_method }}, {{ schema_version }}),
            controller: {{ controller.name.stringify }},
            action: {{ method.name.stringify }},
            request_type: {{ payload_type.name.stringify }},
            response_type: {{ result_type.name.stringify }},
            policies: LF::Microservices::PolicyPlan.new(
              guards: [{% for policy in controller_guards + action_guards %}{{ policy.resolve.name.stringify }},{% end %}] of String,
              pipes: [{% for policy in controller_pipes + action_pipes + argument_pipes %}{{ policy.resolve.name.stringify }},{% end %}] of String,
              interceptors: [{% for policy in controller_interceptors + action_interceptors %}{{ policy.resolve.name.stringify }},{% end %}] of String,
              filters: [{% for policy in action_filters + controller_filters %}{{ policy.resolve.name.stringify }},{% end %}] of String,
            ),
            invoker: LF::Microservices::HandlerInvoker.new do |scope, execution_context, raw_payload|
              filters = [] of LF::Microservices::Filter
              {% for policy in action_filters + controller_filters %}
                filters << scope.resolve({{ policy }}).as(LF::Microservices::Filter)
              {% end %}
              begin
                guards = [] of LF::Microservices::Guard
                {% for policy in controller_guards + action_guards %}
                  guards << scope.resolve({{ policy }}).as(LF::Microservices::Guard)
                {% end %}
                unless LF::Microservices::ExecutionPipeline.authorized?(execution_context, guards)
                  raise LF::Microservices::MessageAuthorizationError.new("message guard denied RPC execution")
                end

                pipes = [] of LF::Microservices::Pipe
                {% for policy in controller_pipes + action_pipes + argument_pipes %}
                  pipes << scope.resolve({{ policy }}).as(LF::Microservices::Pipe)
                {% end %}
                transformed_payload = LF::Microservices::ExecutionPipeline.apply_pipes(
                  raw_payload,
                  LF::Microservices::ArgumentMetadata.new(
                    {{ payload_argument.name.stringify }},
                    {{ payload_type.name.stringify }},
                    LF::Microservices::ArgumentSource::Payload
                  ),
                  execution_context,
                  pipes
                )
                typed_payload = {{ payload_type }}.from_json(transformed_payload.to_json)

                interceptors = [] of LF::Microservices::Interceptor
                {% for policy in controller_interceptors + action_interceptors %}
                  interceptors << scope.resolve({{ policy }}).as(LF::Microservices::Interceptor)
                {% end %}
                LF::Microservices::ExecutionPipeline.intercept(execution_context, interceptors) do
                  controller = scope.resolve({{ controller }})
                  result = controller.{{ method.name }}(typed_payload)
                  {% if result_type == Nil %}
                    JSON::Any.new(nil)
                  {% else %}
                    JSON.parse(result.to_json)
                  {% end %}
                end
              rescue exception : Exception
                if replacement = LF::Microservices::ExecutionPipeline.catch(
                     exception,
                     execution_context,
                     filters
                   )
                  replacement
                else
                  raise exception
                end
              end
            end,
          ))
        {% end %}

        {% for event_annotation in event_annotations %}
          {% namespace = event_annotation[:namespace] %}
          {% service_name = event_annotation[:service] %}
          {% contract_version = event_annotation[:contract_version] %}
          {% event_name = event_annotation[:event] || event_annotation[0] %}
          {% schema_version = event_annotation[:schema_version] %}
          {% subscription = event_annotation[:subscription] %}
          {% mode = event_annotation[:mode] || "service_pool" %}
          {% reliable = event_annotation[:reliable] %}
          {% unless namespace.is_a?(StringLiteral) && service_name.is_a?(StringLiteral) && event_name.is_a?(StringLiteral) && subscription.is_a?(StringLiteral) %}
            {% raise "Invalid event identity on #{controller}##{method.name}: namespace, service, event, and subscription must be string literals" %}
          {% end %}
          {% unless contract_version.is_a?(NumberLiteral) && schema_version.is_a?(NumberLiteral) %}
            {% raise "Invalid event versions on #{controller}##{method.name}: expected integer literals" %}
          {% end %}
          {% unless mode.is_a?(StringLiteral) && {"service_pool", "singleton", "broadcast"}.includes?(mode) %}
            {% raise "Invalid event mode on #{controller}##{method.name}: expected service_pool, singleton, or broadcast" %}
          {% end %}
          {% unless reliable.is_a?(NilLiteral) || reliable.is_a?(BoolLiteral) %}
            {% raise "Invalid event reliability on #{controller}##{method.name}: expected boolean literal" %}
          {% end %}
          {% route = namespace + "." + service_name + ".v" + contract_version.stringify + "." + event_name + ".v" + schema_version.stringify + "." + subscription %}
          {% if event_routes.includes?(route) %}
            {% raise "Duplicate event subscription route #{route} in compiled message controllers" %}
          {% end %}
          {% event_routes << route %}
          {% unless method.args.size == 1 %}
            {% raise "Invalid event handler #{controller}##{method.name}: expected exactly one typed payload argument" %}
          {% end %}
          {% payload_argument = method.args[0] %}
          {% if payload_argument.restriction.is_a?(Nop) %}
            {% raise "Invalid event payload #{controller}##{method.name}: expected an explicit JSON::Serializable type" %}
          {% end %}
          {% payload_type = payload_argument.restriction.resolve %}
          {% unless payload_type.ancestors.includes?(JSON::Serializable) %}
            {% raise "Invalid event payload #{controller}##{method.name}: #{payload_type} must include JSON::Serializable" %}
          {% end %}
          {% if method.return_type.is_a?(Nop) || method.return_type.resolve != Nil %}
            {% raise "Invalid event result #{controller}##{method.name}: expected an explicit Nil return type" %}
          {% end %}

          {% action_guards = [] of ASTNode %}
          {% action_pipes = [] of ASTNode %}
          {% action_interceptors = [] of ASTNode %}
          {% action_filters = [] of ASTNode %}
          {% for policy_annotation in method.annotations(LF::Microservices::UseGuards) %}
            {% for policy in policy_annotation.args %}
              {% unless policy.resolve.ancestors.includes?(LF::Microservices::Guard) %}
                {% raise "Invalid guard #{policy} on #{controller}##{method.name}: expected LF::Microservices::Guard" %}
              {% end %}
              {% action_guards << policy %}
            {% end %}
          {% end %}
          {% for policy_annotation in method.annotations(LF::Microservices::UsePipes) %}
            {% for policy in policy_annotation.args %}
              {% unless policy.resolve.ancestors.includes?(LF::Microservices::Pipe) %}
                {% raise "Invalid pipe #{policy} on #{controller}##{method.name}: expected LF::Microservices::Pipe" %}
              {% end %}
              {% action_pipes << policy %}
            {% end %}
          {% end %}
          {% for policy_annotation in method.annotations(LF::Microservices::UseInterceptors) %}
            {% for policy in policy_annotation.args %}
              {% unless policy.resolve.ancestors.includes?(LF::Microservices::Interceptor) %}
                {% raise "Invalid interceptor #{policy} on #{controller}##{method.name}: expected LF::Microservices::Interceptor" %}
              {% end %}
              {% action_interceptors << policy %}
            {% end %}
          {% end %}
          {% for policy_annotation in method.annotations(LF::Microservices::UseFilters) %}
            {% for policy in policy_annotation.args %}
              {% unless policy.resolve.ancestors.includes?(LF::Microservices::Filter) %}
                {% raise "Invalid filter #{policy} on #{controller}##{method.name}: expected LF::Microservices::Filter" %}
              {% end %}
              {% action_filters << policy %}
            {% end %}
          {% end %}
          {% argument_pipes = [] of ASTNode %}
          {% if pipe_annotation = payload_argument.annotation(LF::Microservices::UsePipes) %}
            {% for policy in pipe_annotation.args %}
              {% unless policy.resolve.ancestors.includes?(LF::Microservices::Pipe) %}
                {% raise "Invalid pipe #{policy} on payload #{controller}##{method.name}: expected LF::Microservices::Pipe" %}
              {% end %}
              {% argument_pipes << policy %}
            {% end %}
          {% end %}

          %registry.add(LF::Microservices::EventHandlerPlan.new(
            identity: LF::Microservices::EventIdentity.new(
              LF::Microservices::ServiceIdentity.new({{ namespace }}, {{ service_name }}, {{ contract_version }}),
              {{ event_name }},
              {{ schema_version }}
            ),
            controller: {{ controller.name.stringify }},
            action: {{ method.name.stringify }},
            payload_type: {{ payload_type.name.stringify }},
            subscription: {{ subscription }},
            mode: {% if mode == "service_pool" %}LF::Microservices::EventDispatchMode::ServicePool{% elsif mode == "singleton" %}LF::Microservices::EventDispatchMode::Singleton{% else %}LF::Microservices::EventDispatchMode::Broadcast{% end %},
            reliable: {{ reliable }},
            policies: LF::Microservices::PolicyPlan.new(
              guards: [{% for policy in controller_guards + action_guards %}{{ policy.resolve.name.stringify }},{% end %}] of String,
              pipes: [{% for policy in controller_pipes + action_pipes + argument_pipes %}{{ policy.resolve.name.stringify }},{% end %}] of String,
              interceptors: [{% for policy in controller_interceptors + action_interceptors %}{{ policy.resolve.name.stringify }},{% end %}] of String,
              filters: [{% for policy in action_filters + controller_filters %}{{ policy.resolve.name.stringify }},{% end %}] of String,
            ),
            invoker: LF::Microservices::HandlerInvoker.new do |scope, execution_context, raw_payload|
              filters = [] of LF::Microservices::Filter
              {% for policy in action_filters + controller_filters %}
                filters << scope.resolve({{ policy }}).as(LF::Microservices::Filter)
              {% end %}
              begin
                guards = [] of LF::Microservices::Guard
                {% for policy in controller_guards + action_guards %}
                  guards << scope.resolve({{ policy }}).as(LF::Microservices::Guard)
                {% end %}
                unless LF::Microservices::ExecutionPipeline.authorized?(execution_context, guards)
                  raise LF::Microservices::MessageAuthorizationError.new("message guard denied event execution")
                end

                pipes = [] of LF::Microservices::Pipe
                {% for policy in controller_pipes + action_pipes + argument_pipes %}
                  pipes << scope.resolve({{ policy }}).as(LF::Microservices::Pipe)
                {% end %}
                transformed_payload = LF::Microservices::ExecutionPipeline.apply_pipes(
                  raw_payload,
                  LF::Microservices::ArgumentMetadata.new(
                    {{ payload_argument.name.stringify }},
                    {{ payload_type.name.stringify }},
                    LF::Microservices::ArgumentSource::Payload
                  ),
                  execution_context,
                  pipes
                )
                typed_payload = {{ payload_type }}.from_json(transformed_payload.to_json)

                interceptors = [] of LF::Microservices::Interceptor
                {% for policy in controller_interceptors + action_interceptors %}
                  interceptors << scope.resolve({{ policy }}).as(LF::Microservices::Interceptor)
                {% end %}
                LF::Microservices::ExecutionPipeline.intercept(execution_context, interceptors) do
                  controller = scope.resolve({{ controller }})
                  controller.{{ method.name }}(typed_payload)
                  JSON::Any.new(nil)
                end
              rescue exception : Exception
                if replacement = LF::Microservices::ExecutionPipeline.catch(
                     exception,
                     execution_context,
                     filters
                   )
                  replacement
                else
                  raise exception
                end
              end
            end,
          ))
        {% end %}
      {% end %}
    {% end %}

    %registry.seal
  end

  # Registers message-scoped controller factories and compiles executable
  # handler plans. Constructor dependencies are resolved from the same message
  # scope that owns controller disposal.
  macro compile_executable_handlers(service, scope_provider, *controller_nodes)
    {% if controller_nodes.empty? %}
      {% raise "Expected at least one LF::Microservices::MessageController" %}
    {% end %}
    {% for controller_node, index in controller_nodes %}
      {% controller = controller_node.resolve %}
      {% unless controller.ancestors.includes?(LF::Microservices::MessageController) %}
        {% raise "Invalid message controller #{controller}: expected LF::Microservices::MessageController" %}
      {% end %}
      {% initializer = controller.methods.find { |candidate| candidate.name.stringify == "initialize" } %}
      {% unless initializer %}
        {% for ancestor in controller.ancestors %}
          {% unless initializer %}
            {% initializer = ancestor.methods.find { |candidate| candidate.name.stringify == "initialize" } %}
          {% end %}
        {% end %}
      {% end %}
      {% if initializer %}
        {% for argument in initializer.args %}
          {% if argument.restriction.is_a?(Nop) %}
            {% raise "Invalid constructor dependency '#{argument.name}' on #{controller}: expected an explicit type" %}
          {% end %}
        {% end %}
      {% end %}

      {{ scope_provider }}.add_bean(
        name: {{ "__lf_message_controller_#{index}_#{controller.name}" }},
        scope: "message",
        type: {{ controller }}
      ) do |scope|
        {% if initializer %}
          {{ controller }}.new(
            {% for argument in initializer.args %}
              scope.resolve_dependency({{ argument.name.stringify }}, {{ argument.restriction }}),
            {% end %}
          )
        {% else %}
          {{ controller }}.new
        {% end %}
      end
    {% end %}

    LF::Microservices.compile_handlers(
      {{ service }},
      {% for controller_node in controller_nodes %}
        {{ controller_node }},
      {% end %}
    )
  end
end
