require "../config_service"
require "../http/execution_pipeline"
require "../http/router"
require "./endpoint"

module LF::LiveView::AutoConfig
  macro mount(router, application_context, global_owner = nil)
    {% pages = LF::LiveView::View.all_subclasses.select do |view|
         !view.abstract? && view.annotation(LF::LiveView::Page)
       end.sort_by(&.name.stringify) %}
    {% unless pages.empty? %}
      {% global_guard_types = [] of ASTNode %}
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
      {% end %}
      live_view_config = {{ application_context }}.resolve(LF::ConfigService)
      live_view_secret = live_view_config.get("live_view.secret", "")
      live_view_endpoint = LF::LiveView::Endpoint.new(
        secret: live_view_secret,
        socket_path: live_view_config.get("live_view.socket_path", LF::LiveView::Endpoint::SOCKET_PATH),
        client_path: live_view_config.get("live_view.client_path", LF::LiveView::Endpoint::CLIENT_PATH),
        allowed_origins: live_view_config.get("live_view.allowed_origins", [] of String),
        mount_token_max_age: live_view_config.get("live_view.mount_token_max_age_ms", 86_400_000).milliseconds,
        max_message_bytes: live_view_config.get("live_view.max_message_bytes", 65_536),
        join_timeout: live_view_config.get("live_view.join_timeout_ms", 10_000).milliseconds,
        idle_timeout: live_view_config.get("live_view.idle_timeout_ms", 75_000).milliseconds,
      )

      {% for view in pages %}
        {% view_guard_types = [] of ASTNode %}
        {% for policy_annotation in view.annotations(LF::HTTP::UseGuards) %}
          {% for policy in policy_annotation.args %}
            {% unless policy.resolve.ancestors.includes?(LF::HTTP::Guard) %}
              {% raise "Invalid guard #{policy} on #{view}: expected LF::HTTP::Guard" %}
            {% end %}
            {% view_guard_types << policy %}
          {% end %}
        {% end %}
        {% annotations = view.annotations(LF::LiveView::Page) %}
        {% if annotations.size != 1 %}
          {% raise "#{view.name} must declare exactly one @[LF::LiveView::Page] annotation" %}
        {% end %}
        {% page_annotation = annotations.first %}
        {% path = page_annotation[0] || page_annotation[:path] || raise "Missing LiveView page path on #{view.name}" %}
        {% initializer = view.methods.find { |method| method.name.stringify == "initialize" } %}
        {% unless initializer %}
          {% for ancestor in view.ancestors %}
            {% unless initializer %}
              {% initializer = ancestor.methods.find { |method| method.name.stringify == "initialize" } %}
            {% end %}
          {% end %}
        {% end %}
        {% request_name = "__lf_live_view_request__" + view.name.stringify %}
        {% websocket_name = "__lf_live_view_websocket__" + view.name.stringify %}

        {{ application_context }}.add_bean(
          name: {{ request_name }},
          scope: "request",
          type: {{ view }}
        ) do |scope|
          {% if initializer %}
            {{ view }}.new(
              {% for argument in initializer.args %}
                scope.resolve_dependency({{ argument.name.stringify }}, {{ argument.restriction }}),
              {% end %}
            )
          {% else %}
            {{ view }}.new
          {% end %}
        end

        {{ application_context }}.add_bean(
          name: {{ websocket_name }},
          scope: "websocket",
          type: {{ view }}
        ) do |scope|
          {% if initializer %}
            {{ view }}.new(
              {% for argument in initializer.args %}
                scope.resolve_dependency({{ argument.name.stringify }}, {{ argument.restriction }}),
              {% end %}
            )
          {% else %}
            {{ view }}.new
          {% end %}
        end

        live_view_guards = ->(scope : LF::DI::Container) do
          guards = [] of LF::HTTP::Guard
          {% for policy in global_guard_types %}
            guards << scope.resolve({{ policy }}).as(LF::HTTP::Guard)
          {% end %}
          {% for policy in view_guard_types %}
            guards << scope.resolve({{ policy }}).as(LF::HTTP::Guard)
          {% end %}
          guards
        end

        live_view_endpoint.page(
          {{ path }},
          {{ view }},
          name: {{ view.name.stringify }},
          managed_by_scope: true,
          guards: live_view_guards
        ) do |scope|
          if scope.scope == "websocket"
            scope.resolve({{ websocket_name }}, {{ view }})
          else
            scope.resolve({{ request_name }}, {{ view }})
          end
        end
      {% end %}

      live_view_endpoint.mount({{ router }})
    {% end %}
  end
end
