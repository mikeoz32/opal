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

  macro __build_routes__
    def setup_routes(router : LF::HTTP::Router)
      {% for method in @type.methods.sort_by(&.line_number) %}
        {% for route_method in {Get, Post, Put, Delete, Patch, Route} %}
          {% router_method = route_method.stringify.split("::")[-1].downcase.id %}
          {% router_method = "add".id if router_method == "route" %}
          {% for ann in method.annotations(route_method) %}
            {% path = ann[0] || ann[:path] || raise "Missing path in #{method.name}" %}
            router.{{ router_method }}({{ path }}) do |ctx, route_params|
              begin
                {% for arg in method.args %}
                  {% if arg.name == "request" && arg.restriction.id == "HTTP::Request" %}
                    {{ arg.name }} = ctx.request
                  {% elsif {"Int32", "Int64", "Float32", "Float64", "Bool", "UUID", "String"}.includes?(arg.restriction.stringify) %}
                    if route_params.has_key?("{{ arg.name }}")
                      {{ arg.name }} = LF::HTTP::ParameterDecoder.decode(route_params, "{{ arg.name }}", {{ arg.restriction }})
                    elsif ctx.request.query_params.has_key?("{{ arg.name }}")
                      {{ arg.name }} = LF::HTTP::ParameterDecoder.decode(ctx.request.query_params, "{{ arg.name }}", {{ arg.restriction }})
                    else
                      raise LF::HTTP::BadRequest.new("Missing required parameter '{{ arg.name }}'")
                    end
                  {% elsif parse_type(arg.restriction.stringify).resolve.ancestors.any? { |ancestor| ancestor.id == "JSON::Serializable" } %}
                    raise LF::HTTP::BadRequest.new("Missing request body") if ctx.request.body.nil?
                    begin
                      {{ arg.name }} = {{ arg.restriction.id }}.from_json(ctx.request.body.as(IO))
                    rescue e : JSON::SerializableError | JSON::ParseException
                      raise LF::HTTP::BadRequest.new(e.message || "Invalid JSON request body")
                    end
                  {% else %}
                    scope = ctx.dependency_scope
                    raise LF::HTTP::InternalServerError.new("DI context not initialized") if scope.nil?
                    {{ arg.name }} = scope.as(LF::DI::Container).resolve_dependency("{{ arg.name }}", {{ arg.restriction }})
                  {% end %}
                {% end %}

                result = {{ method.name }}({% for arg in method.args %}{{ arg.name }},{% end %})
                if result.is_a?(LF::HTTP::Response)
                  result.as(LF::HTTP::Response).write_to(ctx)
                elsif result.is_a?(JSON::Serializable)
                  ctx.response.content_type = "application/json"
                  result.to_json(ctx.response)
                else
                  ctx.response.print result
                end
              rescue e : LF::HTTP::Error
                raise e
              rescue e : Exception
                raise LF::HTTP::InternalServerError.new("Error processing request: #{e.message}")
              end
            end
          {% end %}
        {% end %}
      {% end %}
    end
  end

  macro included
    macro finished
      __build_routes__
    end

    include ::HTTP::Handler

    def call(context : ::HTTP::Server::Context) : Nil
      context.response.status = ::HTTP::Status::METHOD_NOT_ALLOWED
      context.response.content_type = "text/plain"
      context.response.print "Method Not Allowed"
    end
  end
end
