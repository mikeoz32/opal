require "../src/opal"

class GreetingService
  getter prefix : String

  def initialize(@prefix : String)
  end
end

class Message
  include JSON::Serializable

  property message : String

  def initialize(@message : String)
  end
end

class GreetingApi
  include LF::HTTP::Controller

  def initialize(@greeting_service : GreetingService)
  end

  @[LF::HTTP::Controller::Get("/hello/:name")]
  def show(name : String)
    Message.new("#{@greeting_service.prefix}, #{name}")
  end

  @[LF::HTTP::Controller::Get("/echo")]
  def echo(name : String)
    "#{@greeting_service.prefix}, #{name}"
  end
end

root = LF::DI::DefaultContainer.new
root.add_bean(name: "greeting_service", scope: "request", type: GreetingService) do |_ctx|
  GreetingService.new("Hello")
end

app = LF::HTTP::App.new do |router|
  GreetingApi.setup_routes(router, root)
end

server = HTTP::Server.new([
  HTTP::LogHandler.new,
  LF::HTTP::DI::RequestScopeHandler.new(root),
  app,
])

address = server.bind_tcp(8081)
puts "Listening on http://#{address}"
puts "Routes:"
puts "  GET /hello/:name"
puts "  GET /echo?name=..."

begin
  server.listen
ensure
  root.shutdown
end
