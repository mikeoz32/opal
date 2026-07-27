require "./errors"
require "./router"

module LF::HTTP
  class App
    include ::HTTP::Handler

    @router : Router

    def initialize(&block : Router -> Nil)
      @router = Router.new
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
