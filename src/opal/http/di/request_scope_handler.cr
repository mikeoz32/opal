require "../di_integration"

module LF::HTTP::DI
  class RequestScopeHandler
    include ::HTTP::Handler

    def initialize(@root : LF::DI::Container, @scope : String = "request")
    end

    def call(context : ::HTTP::Server::Context) : Nil
      scope = @root.enter_scope(@scope)
      context.dependency_scope = scope
      call_next(context)
    ensure
      begin
        scope.try(&.exit)
      ensure
        context.dependency_scope = nil
      end
    end
  end
end
