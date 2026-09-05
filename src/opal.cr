require "./opal/di"
require "./opal/config_service"
require "./opal/application"
require "./opal/http/app"
require "./opal/http/controller"
require "./opal/http/websocket_request"
require "./opal/http/websocket_connection_registry"
require "./opal/http/autoconfig_middleware"
require "./opal/http/di/request_scope_handler"
require "./opal/http/di/websocket_scope_handler"
require "./opal/http/execution_pipeline"
require "./opal/http/response"
require "./opal/live_view"

# Main namespace for Opal's public Crystal API.
#
# `require "opal"` loads HTTP routing and controllers, dependency injection,
# the application runtime, native WebSockets, and the server side of LiveView.
# Optional subsystems have separate entry points: `opal/data`, `opal/ui`, and
# `opal/security`.
module LF
end
