require "../di_integration"

module LF::HTTP::DI
  class WebSocketScopeHandler
    include ::HTTP::Handler

    def initialize(@root : LF::DI::ScopeProvider, @scope : String = "websocket")
    end

    def call(context : ::HTTP::Server::Context) : Nil
      call_next(context)
      return unless websocket_upgrade_request?(context.request)

      upgrade_handler = context.response.upgrade_handler
      return unless upgrade_handler

      context.response.upgrade_handler = ->(io : IO) {
        scope = @root.enter_scope(@scope)
        previous_scope = context.dependency_scope
        context.dependency_scope = scope

        begin
          upgrade_handler.call(io)
        ensure
          begin
            scope.exit
          ensure
            context.dependency_scope = previous_scope
          end
        end
      }
    end

    private def websocket_upgrade_request?(request : ::HTTP::Request) : Bool
      return false unless upgrade = request.headers["Upgrade"]?
      return false unless upgrade.compare("websocket", case_insensitive: true) == 0

      request.headers.includes_word?("Connection", "Upgrade")
    end
  end
end
