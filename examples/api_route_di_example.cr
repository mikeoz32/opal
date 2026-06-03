require "../src/opal"

class GreetingService
  getter prefix : String

  def initialize(@prefix : String)
  end
end

class RequestScopeHandler
  include HTTP::Handler

  def initialize(@root : LF::DI::AnnotationApplicationContext)
  end

  def call(context)
    scope = @root.enter_scope("request")
    context.state = scope
    call_next(context)
  ensure
    scope.try(&.exit)
  end
end

class Message
  include JSON::Serializable

  property message : String

  def initialize(@message : String)
  end
end

class GreetingApi
  include LF::APIRoute

  @[LF::APIRoute::Get("/hello/:name")]
  def show(name : String, greeting_service : GreetingService)
    LF::JSONResponse.create(Message.new("#{greeting_service.prefix}, #{name}"))
  end

  @[LF::APIRoute::Get("/echo")]
  def echo(name : String, greeting_service : GreetingService)
    "#{greeting_service.prefix}, #{name}"
  end
end

root = LF::DI::AnnotationApplicationContext.new
root.add_bean(name: "greeting_service", scope: "request", type: GreetingService) do |_ctx|
  GreetingService.new("Hello")
end

app = LF::LFApi.new do |router|
  GreetingApi.new.setup_routes(router)
end

server = HTTP::Server.new([
  HTTP::LogHandler.new,
  RequestScopeHandler.new(root),
  app,
])

address = server.bind_tcp(8081)
puts "Listening on http://#{address}"
puts "Routes:"
puts "  GET /hello/:name"
puts "  GET /echo?name=..."

server.listen
