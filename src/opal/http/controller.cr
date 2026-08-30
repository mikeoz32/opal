require "json"
require "./di_integration"
require "./errors"
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

  macro included
    {% verbatim do %}
      macro setup_routes(router, scope_provider)
        {% controller_type = @type %}
        {% controller_name = "__lf_http_controller__" + controller_type.name.stringify %}
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

              {% for argument in method.args %}
                {% restriction = argument.restriction %}
                {% request_argument = argument.name.stringify == "request" && restriction.stringify == "HTTP::Request" %}
                {% scalar_argument = {"Int32", "Int64", "Float32", "Float64", "Bool", "UUID", "String"}.includes?(restriction.stringify) %}
                {% json_argument = !restriction.is_a?(Nop) && parse_type(restriction.stringify).resolve.ancestors.any? { |ancestor| ancestor.id == "JSON::Serializable" } %}
                {% unless request_argument || scalar_argument || json_argument %}
                  {% raise "Invalid route argument '#{argument.name}' in #{controller_type}##{method.name}: inject services through the controller constructor" %}
                {% end %}
              {% end %}

              {{ router }}.{{ router_method }}({{ path }}) do |ctx, route_params|
                begin
                  scope = ctx.dependency_scope
                  raise LF::HTTP::InternalServerError.new("DI context not initialized") if scope.nil?

                  {% for argument in method.args %}
                    {% if argument.name.stringify == "request" && argument.restriction.stringify == "HTTP::Request" %}
                      {{ argument.name }} = ctx.request
                    {% elsif {"Int32", "Int64", "Float32", "Float64", "Bool", "UUID", "String"}.includes?(argument.restriction.stringify) %}
                      if route_params.has_key?({{ argument.name.stringify }})
                        {{ argument.name }} = LF::HTTP::ParameterDecoder.decode(route_params, {{ argument.name.stringify }}, {{ argument.restriction }})
                      elsif ctx.request.query_params.has_key?({{ argument.name.stringify }})
                        {{ argument.name }} = LF::HTTP::ParameterDecoder.decode(ctx.request.query_params, {{ argument.name.stringify }}, {{ argument.restriction }})
                      else
                        raise LF::HTTP::BadRequest.new({{ "Missing required parameter '#{argument.name}'" }})
                      end
                    {% else %}
                      raise LF::HTTP::BadRequest.new("Missing request body") if ctx.request.body.nil?
                      begin
                        {{ argument.name }} = {{ argument.restriction }}.from_json(ctx.request.body.as(IO))
                      rescue error : JSON::SerializableError | JSON::ParseException
                        raise LF::HTTP::BadRequest.new(error.message || "Invalid JSON request body")
                      end
                    {% end %}
                  {% end %}

                  controller = scope.as(LF::DI::Container).resolve({{ controller_name }}, {{ controller_type }})
                  result = controller.{{ method.name }}(
                    {% for argument in method.args %}
                      {{ argument.name }},
                    {% end %}
                  )
                  if result.is_a?(LF::HTTP::Response)
                    result.as(LF::HTTP::Response).write_to(ctx)
                  elsif result.is_a?(JSON::Serializable)
                    ctx.response.content_type = "application/json"
                    result.to_json(ctx.response)
                  else
                    ctx.response.content_type = "text/plain"
                    ctx.response.print result
                  end
                rescue error : LF::HTTP::Error
                  raise error
                rescue error : Exception
                  raise LF::HTTP::InternalServerError.new("Error processing request: #{error.message}")
                end
              end
            {% end %}
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
