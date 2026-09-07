# Tutorial: your first HTTP API

In this tutorial you will build a small in-memory API. It demonstrates the
normal Opal application boundary: dependencies live in a root container,
controllers are request-scoped, and request arguments are only data supplied
by the client.

## 1. Define a request and response model

Create `src/app.cr` and start with serializable data:

```crystal
--8<-- "examples/documentation/first_api.cr:imports"

--8<-- "examples/documentation/first_api.cr:models"
```

An action with one `JSON::Serializable` argument receives the JSON request
body. A returned `JSON::Serializable` value becomes a JSON response.

## 2. Add an application service

Services are ordinary Crystal classes. Mark one with `@[LF::DI::Service]` when
the generated `LF::DI::ServiceConfiguration` should create it.

```crystal
--8<-- "examples/documentation/first_api.cr:service"
```

## 3. Declare a controller

Include `LF::HTTP::Controller`, inject the service through the constructor, and
put an HTTP verb annotation on each public action.

```crystal
--8<-- "examples/documentation/first_api.cr:controller"
```

`id` is decoded from the route path and `payload` from the request body. It is
a compile-time error to ask Opal to inject an application service as an action
argument; constructor injection makes that ownership explicit.

## 4. Assemble the server

The request-scope handler must be earlier in the handler chain than the app.
It creates and closes one DI scope around every HTTP request.

```crystal
--8<-- "examples/documentation/first_api.cr:server"
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
