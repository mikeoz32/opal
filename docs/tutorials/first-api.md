# Tutorial: your first HTTP API

In this tutorial you will build a small in-memory API. It demonstrates the
normal Opal application boundary: dependencies live in a root container,
controllers are request-scoped, and request arguments are only data supplied
by the client.

## 1. Define a request and response model

Create `src/app.cr` and start with serializable data:

```crystal
require "opal"

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
```

An action with one `JSON::Serializable` argument receives the JSON request
body. A returned `JSON::Serializable` value becomes a JSON response.

## 2. Add an application service

Services are ordinary Crystal classes. Mark one with `@[LF::DI::Service]` when
the generated `LF::DI::ServiceConfiguration` should create it.

```crystal
@[LF::DI::Service]
class Greetings
  @next_id = 1

  def create(name : String) : Greeting
    id = @next_id
    @next_id += 1
    Greeting.new(id, "Hello, #{name.strip}")
  end
end
```

## 3. Declare a controller

Include `LF::HTTP::Controller`, inject the service through the constructor, and
put an HTTP verb annotation on each public action.

```crystal
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
```

`id` is decoded from the route path and `payload` from the request body. It is
a compile-time error to ask Opal to inject an application service as an action
argument; constructor injection makes that ownership explicit.

## 4. Assemble the server

The request-scope handler must be earlier in the handler chain than the app.
It creates and closes one DI scope around every HTTP request.

```crystal
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
server.listen
```

Run it with `crystal run src/app.cr`, then make a request:

```bash
curl -i http://127.0.0.1:8080/greetings/7
curl -i -X POST http://127.0.0.1:8080/greetings \
  -H 'content-type: application/json' \
  -d '{"name":"Ada"}'
```

## What to do next

- Add input transformation, authorization, response timing, and exception
  mapping with [controller policies](../guides/http-controllers.md).
- Replace the in-memory service with an explicit repository by completing the
  [Todo API tutorial](todo-api.md).
- Use `@[LF::Application]` and HTTP autoconfiguration when the application has
  multiple controllers and a configuration file.
