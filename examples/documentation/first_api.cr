# --8<-- [start:imports]
require "opal"

# --8<-- [end:imports]

# --8<-- [start:models]
class CreateGreeting
  include JSON::Serializable

  property name : String
end

class Greeting
  include JSON::Serializable

  getter id : Int32
  getter message : String

  def initialize(@id : Int32, @message : String)
  end
end

# --8<-- [end:models]

# --8<-- [start:service]
@[LF::DI::Service]
class Greetings
  @next_id = 1

  def create(name : String) : Greeting
    id = @next_id
    @next_id += 1
    Greeting.new(id, "Hello, #{name.strip}")
  end
end

# --8<-- [end:service]

# --8<-- [start:controller]
class GreetingsApi
  include LF::HTTP::Controller

  def initialize(@greetings : Greetings)
  end

  @[LF::HTTP::Controller::Post("/greetings")]
  def create(payload : CreateGreeting) : Greeting
    @greetings.create(payload.name)
  end

  @[LF::HTTP::Controller::Get("/greetings/:id")]
  def show(id : Int32) : Greeting
    Greeting.new(id, "Hello again")
  end
end

# --8<-- [end:controller]

# --8<-- [start:server]
root = LF::DI::DefaultContainer.new
root.register(LF::DI::ServiceConfiguration.new)

app = LF::HTTP::App.new do |router|
  GreetingsApi.setup_routes(router, root)
end

server = HTTP::Server.new([
  HTTP::LogHandler.new,
  LF::HTTP::DI::RequestScopeHandler.new(root),
  app,
])

server.bind_tcp(8080)
begin
  server.listen
ensure
  root.shutdown
end
# --8<-- [end:server]
