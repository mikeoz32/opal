require "./errors"
require "./router"

module LF::HTTP
  # An `HTTP::Handler` wrapper around `Router` with a consistent exception
  # boundary for an Opal application.
  #
  # `LF::HTTP::Error` values become their declared status and message. Other
  # exceptions become a plain `500 Internal Server Error`, avoiding accidental
  # error-detail exposure. Use a `Router` directly only when a different
  # low-level error contract is required.
  class App
    include ::HTTP::Handler

    @router : Router

    # Creates an application and yields its router for route registration.
    def initialize(&block : Router -> Nil)
      @router = Router.new
      yield @router
    end

    def initialize(error_mapper : Router::ErrorMapper, &block : Router -> Nil)
      @router = Router.new(error_mapper)
      yield @router
    end

    def initialize
      @router = Router.new
    end

    def call(context : ::HTTP::Server::Context) : Nil
      @router.call(context)
    rescue e : Error
      context.response.status = e.status_code
      context.response.content_type = "text/plain"
      context.response.print e.message
    rescue e : Exception
      context.response.status = ::HTTP::Status::INTERNAL_SERVER_ERROR
      context.response.content_type = "text/plain"
      context.response.print "Internal Server Error"
    end
  end
end
