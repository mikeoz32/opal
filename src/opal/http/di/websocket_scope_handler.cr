require "../di_integration"
require "../websocket_request"

module LF::HTTP::DI
  class WebSocketScopeHandler
    include ::HTTP::Handler

    def initialize(
      @root : LF::DI::ScopeProvider,
      @scope : String = "websocket",
      @connections : LF::HTTP::WebSocketConnectionRegistry? = nil,
    )
    end

    def call(context : ::HTTP::Server::Context) : Nil
      call_next(context)
      return unless LF::HTTP::WebSocketRequest.upgrade?(context.request)

      upgrade_handler = context.response.upgrade_handler
      return unless upgrade_handler

      context.response.upgrade_handler = ->(io : IO) {
        scope = @root.enter_scope(@scope)
        previous_scope = context.dependency_scope
        previous_upgrade = context.websocket_upgrade
        context.dependency_scope = scope
        context.dependency_scope_initializer.try(&.call(scope))
        context.websocket_upgrade = LF::HTTP::WebSocketUpgrade.new(io, @connections)

        begin
          upgrade_handler.call(io)
        ensure
          begin
            if upgrade = context.websocket_upgrade
              if connection = upgrade.connection
                upgrade.registry.try(&.unregister(connection))
              end
            end
            context.websocket_upgrade = previous_upgrade
          ensure
            begin
              scope.exit
            ensure
              context.dependency_scope = previous_scope
            end
          end
        end
      }
    end
  end
end
