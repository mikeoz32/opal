require "json"
require "log"
require "./di_integration"
require "./errors"
require "./execution_pipeline"
require "./parameter_decoder"
require "./response"
require "./router"

module LF::HTTP::Controller
  annotation Route
  end

  annotation Get
  end

  annotation Post
  end

  annotation Put
  end

  annotation Delete
  end

  annotation Patch
  end

  annotation Head
  end

  annotation Options
  end

  annotation WebSocket
  end

  macro included
    {% verbatim do %}
      macro setup_routes(router, scope_provider, global_owner = nil)
        {% controller_type = @type %}
        {% controller_name = "__lf_http_controller__" + controller_type.name.stringify %}
        {% websocket_controller_name = "__lf_http_websocket_controller__" + controller_type.name.stringify %}
        {% global_guard_types = [] of ASTNode %}
        {% global_pipe_types = [] of ASTNode %}
        {% global_interceptor_types = [] of ASTNode %}
        {% global_filter_types = [] of ASTNode %}
        {% unless global_owner.is_a?(NilLiteral) %}
          {% global_owner_type = global_owner.resolve %}
          {% for policy_annotation in global_owner_type.annotations(LF::HTTP::UseGuards) %}
            {% for policy in policy_annotation.args %}
              {% unless policy.resolve.ancestors.includes?(LF::HTTP::Guard) %}
                {% raise "Invalid guard #{policy} on #{global_owner_type}: expected LF::HTTP::Guard" %}
              {% end %}
              {% global_guard_types << policy %}
            {% end %}
          {% end %}
          {% for policy_annotation in global_owner_type.annotations(LF::HTTP::UsePipes) %}
            {% for policy in policy_annotation.args %}
              {% unless policy.resolve.ancestors.includes?(LF::HTTP::Pipe) %}
                {% raise "Invalid pipe #{policy} on #{global_owner_type}: expected LF::HTTP::Pipe" %}
              {% end %}
              {% global_pipe_types << policy %}
            {% end %}
          {% end %}
          {% for policy_annotation in global_owner_type.annotations(LF::HTTP::UseInterceptors) %}
            {% for policy in policy_annotation.args %}
              {% unless policy.resolve.ancestors.includes?(LF::HTTP::Interceptor) %}
                {% raise "Invalid interceptor #{policy} on #{global_owner_type}: expected LF::HTTP::Interceptor" %}
              {% end %}
              {% global_interceptor_types << policy %}
            {% end %}
          {% end %}
          {% for policy_annotation in global_owner_type.annotations(LF::HTTP::UseFilters) %}
            {% for policy in policy_annotation.args %}
              {% unless policy.resolve.ancestors.includes?(LF::HTTP::Filter) %}
                {% raise "Invalid filter #{policy} on #{global_owner_type}: expected LF::HTTP::Filter" %}
              {% end %}
              {% global_filter_types << policy %}
            {% end %}
          {% end %}
        {% end %}
        {% controller_guard_types = [] of ASTNode %}
        {% controller_pipe_types = [] of ASTNode %}
        {% controller_interceptor_types = [] of ASTNode %}
        {% controller_filter_types = [] of ASTNode %}
        {% for policy_annotation in controller_type.annotations(LF::HTTP::UseGuards) %}
          {% for policy in policy_annotation.args %}
            {% unless policy.resolve.ancestors.includes?(LF::HTTP::Guard) %}
              {% raise "Invalid guard #{policy} on #{controller_type}: expected LF::HTTP::Guard" %}
            {% end %}
            {% controller_guard_types << policy %}
          {% end %}
        {% end %}
        {% for policy_annotation in controller_type.annotations(LF::HTTP::UsePipes) %}
          {% for policy in policy_annotation.args %}
            {% unless policy.resolve.ancestors.includes?(LF::HTTP::Pipe) %}
              {% raise "Invalid pipe #{policy} on #{controller_type}: expected LF::HTTP::Pipe" %}
            {% end %}
            {% controller_pipe_types << policy %}
          {% end %}
        {% end %}
        {% for policy_annotation in controller_type.annotations(LF::HTTP::UseInterceptors) %}
          {% for policy in policy_annotation.args %}
            {% unless policy.resolve.ancestors.includes?(LF::HTTP::Interceptor) %}
              {% raise "Invalid interceptor #{policy} on #{controller_type}: expected LF::HTTP::Interceptor" %}
            {% end %}
            {% controller_interceptor_types << policy %}
          {% end %}
        {% end %}
        {% for policy_annotation in controller_type.annotations(LF::HTTP::UseFilters) %}
          {% for policy in policy_annotation.args %}
            {% unless policy.resolve.ancestors.includes?(LF::HTTP::Filter) %}
              {% raise "Invalid filter #{policy} on #{controller_type}: expected LF::HTTP::Filter" %}
            {% end %}
            {% controller_filter_types << policy %}
          {% end %}
        {% end %}
        {% initializer = controller_type.methods.find { |method| method.name.stringify == "initialize" } %}
        {% unless initializer %}
          {% for ancestor in controller_type.ancestors %}
            {% unless initializer %}
              {% initializer = ancestor.methods.find { |method| method.name.stringify == "initialize" } %}
            {% end %}
          {% end %}
        {% end %}

        {{ scope_provider }}.add_bean(
          name: {{ controller_name }},
          scope: "request",
          type: {{ controller_type }}
        ) do |scope|
          {% if initializer %}
            {{ controller_type }}.new(
              {% for argument in initializer.args %}
                scope.resolve_dependency({{ argument.name.stringify }}, {{ argument.restriction }}),
              {% end %}
            )
          {% else %}
            {{ controller_type }}.new
          {% end %}
        end

        {% for method in controller_type.methods.sort_by(&.line_number) %}
          {% for route_method in {LF::HTTP::Controller::Get, LF::HTTP::Controller::Post, LF::HTTP::Controller::Put, LF::HTTP::Controller::Delete, LF::HTTP::Controller::Patch, LF::HTTP::Controller::Head, LF::HTTP::Controller::Options, LF::HTTP::Controller::Route} %}
            {% router_method = route_method.stringify.split("::")[-1].downcase.id %}
            {% router_method = "add".id if router_method == "route" %}
            {% for ann in method.annotations(route_method) %}
              {% path = ann[0] || ann[:path] || raise "Missing path in #{controller_type}##{method.name}" %}
              {% action_guard_types = [] of ASTNode %}
              {% action_pipe_types = [] of ASTNode %}
              {% action_interceptor_types = [] of ASTNode %}
              {% action_filter_types = [] of ASTNode %}
              {% for policy_annotation in method.annotations(LF::HTTP::UseGuards) %}
                {% for policy in policy_annotation.args %}
                  {% unless policy.resolve.ancestors.includes?(LF::HTTP::Guard) %}
                    {% raise "Invalid guard #{policy} on #{controller_type}##{method.name}: expected LF::HTTP::Guard" %}
                  {% end %}
                  {% action_guard_types << policy %}
                {% end %}
              {% end %}
              {% for policy_annotation in method.annotations(LF::HTTP::UsePipes) %}
                {% for policy in policy_annotation.args %}
                  {% unless policy.resolve.ancestors.includes?(LF::HTTP::Pipe) %}
                    {% raise "Invalid pipe #{policy} on #{controller_type}##{method.name}: expected LF::HTTP::Pipe" %}
                  {% end %}
                  {% action_pipe_types << policy %}
                {% end %}
              {% end %}
              {% for policy_annotation in method.annotations(LF::HTTP::UseInterceptors) %}
                {% for policy in policy_annotation.args %}
                  {% unless policy.resolve.ancestors.includes?(LF::HTTP::Interceptor) %}
                    {% raise "Invalid interceptor #{policy} on #{controller_type}##{method.name}: expected LF::HTTP::Interceptor" %}
                  {% end %}
                  {% action_interceptor_types << policy %}
                {% end %}
              {% end %}
              {% for policy_annotation in method.annotations(LF::HTTP::UseFilters) %}
                {% for policy in policy_annotation.args %}
                  {% unless policy.resolve.ancestors.includes?(LF::HTTP::Filter) %}
                    {% raise "Invalid filter #{policy} on #{controller_type}##{method.name}: expected LF::HTTP::Filter" %}
                  {% end %}
                  {% action_filter_types << policy %}
                {% end %}
              {% end %}

              {% json_arguments = [] of ASTNode %}
              {% for argument in method.args %}
                {% restriction = argument.restriction %}
                {% request_argument = argument.name.stringify == "request" && restriction.stringify == "HTTP::Request" %}
                {% scalar_argument = {"Int32", "Int64", "Float32", "Float64", "Bool", "UUID", "String"}.includes?(restriction.stringify) %}
                {% json_argument = !restriction.is_a?(Nop) && parse_type(restriction.stringify).resolve.ancestors.any? { |ancestor| ancestor.id == "JSON::Serializable" } %}
                {% unless request_argument || scalar_argument || json_argument %}
                  {% raise "Invalid route argument '#{argument.name}' in #{controller_type}##{method.name}: inject services through the controller constructor" %}
                {% end %}
                {% json_arguments << argument if json_argument %}
                {% if pipe_annotation = argument.annotation(LF::HTTP::UsePipes) %}
                  {% if request_argument %}
                    {% raise "Invalid pipes on HTTP::Request argument '#{argument.name}' in #{controller_type}##{method.name}" %}
                  {% end %}
                  {% for policy in pipe_annotation.args %}
                    {% unless policy.resolve.ancestors.includes?(LF::HTTP::Pipe) %}
                      {% raise "Invalid pipe #{policy} on argument '#{argument.name}' in #{controller_type}##{method.name}: expected LF::HTTP::Pipe" %}
                    {% end %}
                  {% end %}
                {% end %}
              {% end %}
              {% if json_arguments.size > 1 %}
                {% raise "Invalid route #{controller_type}##{method.name}: expected at most one JSON body argument" %}
              {% end %}
              {% has_base_pipes = global_pipe_types.size > 0 || controller_pipe_types.size > 0 || action_pipe_types.size > 0 %}
              {% has_parameter_pipes = method.args.any? { |argument| !argument.annotation(LF::HTTP::UsePipes).nil? } %}
              {% has_any_pipes = has_base_pipes || has_parameter_pipes %}

              {{ router }}.{{ router_method }}({{ path }}) do |ctx, route_params|
                execution_context = LF::HTTP::ExecutionContext.new(
                  ctx,
                  route_params,
                  {{ controller_type.name.stringify }},
                  {{ method.name.stringify }}
                )
                scope = execution_context.dependency_scope
                filters = [] of LF::HTTP::Filter
                begin
                  {% for policy in action_filter_types %}
                    filters << scope.resolve({{ policy }}).as(LF::HTTP::Filter)
                  {% end %}
                  {% for policy in controller_filter_types %}
                    filters << scope.resolve({{ policy }}).as(LF::HTTP::Filter)
                  {% end %}
                  {% for policy in global_filter_types %}
                    filters << scope.resolve({{ policy }}).as(LF::HTTP::Filter)
                  {% end %}

                  {% for policy in global_guard_types %}
                    unless scope.resolve({{ policy }}).can_activate(execution_context)
                      raise LF::HTTP::Forbidden.new
                    end
                  {% end %}
                  {% for policy in controller_guard_types %}
                    unless scope.resolve({{ policy }}).can_activate(execution_context)
                      raise LF::HTTP::Forbidden.new
                    end
                  {% end %}
                  {% for policy in action_guard_types %}
                    unless scope.resolve({{ policy }}).can_activate(execution_context)
                      raise LF::HTTP::Forbidden.new
                    end
                  {% end %}

                  interceptors = [] of LF::HTTP::Interceptor
                  {% for policy in global_interceptor_types %}
                    interceptors << scope.resolve({{ policy }}).as(LF::HTTP::Interceptor)
                  {% end %}
                  {% for policy in controller_interceptor_types %}
                    interceptors << scope.resolve({{ policy }}).as(LF::HTTP::Interceptor)
                  {% end %}
                  {% for policy in action_interceptor_types %}
                    interceptors << scope.resolve({{ policy }}).as(LF::HTTP::Interceptor)
                  {% end %}

                  response = LF::HTTP::ExecutionPipeline.intercept(execution_context, interceptors) do
                    {% if has_any_pipes %}
                      pipes = [] of LF::HTTP::Pipe
                      {% for policy in global_pipe_types %}
                        pipes << scope.resolve({{ policy }}).as(LF::HTTP::Pipe)
                      {% end %}
                      {% for policy in controller_pipe_types %}
                        pipes << scope.resolve({{ policy }}).as(LF::HTTP::Pipe)
                      {% end %}
                      {% for policy in action_pipe_types %}
                        pipes << scope.resolve({{ policy }}).as(LF::HTTP::Pipe)
                      {% end %}
                    {% end %}

                    {% for argument in method.args %}
                      {% argument_name = argument.name.stringify %}
                      {% argument_pipe_annotation = argument.annotation(LF::HTTP::UsePipes) %}
                      {% has_argument_pipes = has_base_pipes || !argument_pipe_annotation.nil? %}
                      {% if argument_name == "request" && argument.restriction.stringify == "HTTP::Request" %}
                        {{ argument.name }} = ctx.request
                      {% elsif {"Int32", "Int64", "Float32", "Float64", "Bool", "UUID", "String"}.includes?(argument.restriction.stringify) %}
                        {% if has_argument_pipes %}
                          if route_params.has_key?({{ argument_name }})
                            raw_value = route_params[{{ argument_name }}]
                            argument_source = LF::HTTP::ArgumentSource::Path
                          elsif ctx.request.query_params.has_key?({{ argument_name }})
                            raw_value = ctx.request.query_params[{{ argument_name }}]
                            argument_source = LF::HTTP::ArgumentSource::Query
                          else
                            raise LF::HTTP::BadRequest.new({{ "Missing required parameter '#{argument.name}'" }})
                          end
                          argument_pipes = pipes.dup
                          {% if argument_pipe_annotation %}
                            {% for policy in argument_pipe_annotation.args %}
                              argument_pipes << scope.resolve({{ policy }}).as(LF::HTTP::Pipe)
                            {% end %}
                          {% end %}
                          piped_value = LF::HTTP::ExecutionPipeline.apply_pipes(
                            raw_value,
                            LF::HTTP::ArgumentMetadata.new({{ argument_name }}, {{ argument.restriction.stringify }}, argument_source),
                            execution_context,
                            argument_pipes
                          )
                          unless piped_value.is_a?(String)
                            raise LF::HTTP::InternalServerError.new({{ "Pipe returned an invalid value for parameter '#{argument.name}': expected String" }})
                          end
                          {{ argument.name }} = LF::HTTP::ParameterDecoder.decode(
                            piped_value.as(String),
                            {{ argument_name }},
                            {{ argument.restriction }}
                          )
                        {% else %}
                          if route_params.has_key?({{ argument_name }})
                            {{ argument.name }} = LF::HTTP::ParameterDecoder.decode(route_params, {{ argument_name }}, {{ argument.restriction }})
                          elsif ctx.request.query_params.has_key?({{ argument_name }})
                            {{ argument.name }} = LF::HTTP::ParameterDecoder.decode(ctx.request.query_params, {{ argument_name }}, {{ argument.restriction }})
                          else
                            raise LF::HTTP::BadRequest.new({{ "Missing required parameter '#{argument.name}'" }})
                          end
                        {% end %}
                      {% else %}
                        body = ctx.request.body
                        raise LF::HTTP::BadRequest.new("Missing request body") if body.nil?
                        begin
                          {% if has_argument_pipes %}
                            raw_value = JSON.parse(body.as(IO))
                            argument_pipes = pipes.dup
                            {% if argument_pipe_annotation %}
                              {% for policy in argument_pipe_annotation.args %}
                                argument_pipes << scope.resolve({{ policy }}).as(LF::HTTP::Pipe)
                              {% end %}
                            {% end %}
                            piped_value = LF::HTTP::ExecutionPipeline.apply_pipes(
                              raw_value,
                              LF::HTTP::ArgumentMetadata.new({{ argument_name }}, {{ argument.restriction.stringify }}, LF::HTTP::ArgumentSource::Body),
                              execution_context,
                              argument_pipes
                            )
                            unless piped_value.is_a?(JSON::Any)
                              raise LF::HTTP::InternalServerError.new({{ "Pipe returned an invalid value for parameter '#{argument.name}': expected JSON::Any" }})
                            end
                            {{ argument.name }} = {{ argument.restriction }}.from_json(piped_value.as(JSON::Any).to_json)
                          {% else %}
                            {{ argument.name }} = {{ argument.restriction }}.from_json(body.as(IO))
                          {% end %}
                        rescue error : JSON::SerializableError | JSON::ParseException
                          raise LF::HTTP::BadRequest.new(error.message || "Invalid JSON request body")
                        end
                      {% end %}
                    {% end %}

                    controller = scope.resolve({{ controller_name }}, {{ controller_type }})
                    action_result = controller.{{ method.name }}(
                      {% for argument in method.args %}
                        {{ argument.name }},
                      {% end %}
                    )
                    if action_result.is_a?(LF::HTTP::Response)
                      action_result.as(LF::HTTP::Response)
                    elsif action_result.is_a?(JSON::Serializable)
                      LF::HTTP::JSONResponse.create(action_result)
                    else
                      LF::HTTP::TextResponse.create(action_result.to_s)
                    end
                  end
                  response.write_to(ctx)
                rescue error : Exception
                  if filtered_response = LF::HTTP::ExecutionPipeline.catch(error, execution_context, filters)
                    filtered_response.write_to(ctx)
                  elsif error.is_a?(LF::HTTP::Error)
                    raise error.as(LF::HTTP::Error)
                  else
                    raise LF::HTTP::InternalServerError.new("Error processing request: #{error.message}")
                  end
                end
              end
            {% end %}
          {% end %}
        {% end %}

        {% websocket_methods = controller_type.methods.select { |method| !method.annotations(LF::HTTP::Controller::WebSocket).empty? } %}
        {% if websocket_methods.size > 0 %}
          {{ scope_provider }}.add_bean(
            name: {{ websocket_controller_name }},
            scope: "websocket",
            type: {{ controller_type }}
          ) do |scope|
            {% if initializer %}
              {{ controller_type }}.new(
                {% for argument in initializer.args %}
                  scope.resolve_dependency({{ argument.name.stringify }}, {{ argument.restriction }}),
                {% end %}
              )
            {% else %}
              {{ controller_type }}.new
            {% end %}
          end
        {% end %}
        {% for method in controller_type.methods.sort_by(&.line_number) %}
          {% for ann in method.annotations(LF::HTTP::Controller::WebSocket) %}
            {% path = ann[0] || ann[:path] || raise "Missing path in #{controller_type}##{method.name}" %}
            {% protocols = ann[:protocols] %}
            {% websocket_action_guard_types = [] of ASTNode %}
            {% for policy_annotation in method.annotations(LF::HTTP::UseGuards) %}
              {% for policy in policy_annotation.args %}
                {% unless policy.resolve.ancestors.includes?(LF::HTTP::Guard) %}
                  {% raise "Invalid guard #{policy} on #{controller_type}##{method.name}: expected LF::HTTP::Guard" %}
                {% end %}
                {% websocket_action_guard_types << policy %}
              {% end %}
            {% end %}
            {% websocket_arguments = method.args.select { |argument| argument.restriction.stringify == "HTTP::WebSocket" } %}
            {% request_arguments = method.args.select { |argument| argument.name.stringify == "request" && argument.restriction.stringify == "HTTP::Request" } %}

            {% unless websocket_arguments.size == 1 %}
              {% raise "Invalid websocket route #{controller_type}##{method.name}: expected exactly one HTTP::WebSocket argument" %}
            {% end %}
            {% if request_arguments.size > 1 %}
              {% raise "Invalid websocket route #{controller_type}##{method.name}: expected at most one HTTP::Request argument" %}
            {% end %}
            {% if method.return_type.nil? || method.return_type.stringify != "Nil" %}
              {% raise "Invalid websocket route #{controller_type}##{method.name}: websocket actions must declare an explicit : Nil return type" %}
            {% end %}

            {% for argument in method.args %}
              {% restriction = argument.restriction %}
              {% websocket_argument = restriction.stringify == "HTTP::WebSocket" %}
              {% request_argument = argument.name.stringify == "request" && restriction.stringify == "HTTP::Request" %}
              {% scalar_argument = {"Int32", "Int64", "Float32", "Float64", "Bool", "UUID", "String"}.includes?(restriction.stringify) %}
              {% unless websocket_argument || request_argument || scalar_argument %}
                {% raise "Invalid websocket route argument '#{argument.name}' in #{controller_type}##{method.name}: expected HTTP::WebSocket, HTTP::Request, or a scalar route/query parameter" %}
              {% end %}
            {% end %}

            websocket_before_upgrade = ->(ctx : ::HTTP::Server::Context, route_params : Hash(String, String)) do
              execution_context = LF::HTTP::ExecutionContext.new(
                ctx,
                route_params,
                {{ controller_type.name.stringify }},
                {{ method.name.stringify }}
              )
              scope = execution_context.dependency_scope
              {% for policy in global_guard_types %}
                unless scope.resolve({{ policy }}).can_activate(execution_context)
                  raise LF::HTTP::Forbidden.new
                end
              {% end %}
              {% for policy in controller_guard_types %}
                unless scope.resolve({{ policy }}).can_activate(execution_context)
                  raise LF::HTTP::Forbidden.new
                end
              {% end %}
              {% for policy in websocket_action_guard_types %}
                unless scope.resolve({{ policy }}).can_activate(execution_context)
                  raise LF::HTTP::Forbidden.new
                end
              {% end %}
            end

            {% if protocols %}
              {{ router }}.ws_with_context(
                {{ path }},
                protocols: {{ protocols }},
                before_upgrade: websocket_before_upgrade
              ) do |websocket, route_params, ctx|
            {% else %}
              {{ router }}.ws_with_context(
                {{ path }},
                before_upgrade: websocket_before_upgrade
              ) do |websocket, route_params, ctx|
            {% end %}
                begin
                  scope = ctx.dependency_scope
                  raise LF::HTTP::InternalServerError.new("DI context not initialized") if scope.nil?

                  {% for argument in method.args %}
                    {% restriction = argument.restriction %}
                    {% if restriction.stringify == "HTTP::WebSocket" %}
                      {{ argument.name }} = websocket
                    {% elsif argument.name.stringify == "request" && restriction.stringify == "HTTP::Request" %}
                      {{ argument.name }} = ctx.request
                    {% elsif {"Int32", "Int64", "Float32", "Float64", "Bool", "UUID", "String"}.includes?(restriction.stringify) %}
                      if route_params.has_key?({{ argument.name.stringify }})
                        {{ argument.name }} = LF::HTTP::ParameterDecoder.decode(route_params, {{ argument.name.stringify }}, {{ restriction }})
                      elsif ctx.request.query_params.has_key?({{ argument.name.stringify }})
                        {{ argument.name }} = LF::HTTP::ParameterDecoder.decode(ctx.request.query_params, {{ argument.name.stringify }}, {{ restriction }})
                      else
                        raise LF::HTTP::BadRequest.new({{ "Missing required parameter '#{argument.name}'" }})
                      end
                    {% end %}
                  {% end %}

                  controller = scope.as(LF::DI::Container).resolve({{ websocket_controller_name }}, {{ controller_type }})
                  controller.{{ method.name }}(
                    {% for argument in method.args %}
                      {{ argument.name }},
                    {% end %}
                  )
                rescue error : Exception
                  Log.error(exception: error) { {{ "WebSocket route failed: #{path}" }} }
                  websocket.close(::HTTP::WebSocket::CloseCode::InternalServerError)
                end
            end
          {% end %}
        {% end %}
      end
    {% end %}

    include ::HTTP::Handler

    def call(context : ::HTTP::Server::Context) : Nil
      context.response.status = ::HTTP::Status::METHOD_NOT_ALLOWED
      context.response.content_type = "text/plain"
      context.response.print "Method Not Allowed"
    end
  end
end
