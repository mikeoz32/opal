require "../src/opal"

# Example JSON model
class User
  include JSON::Serializable

  property id : Int32
  property name : String
  property email : String

  def initialize(@id : Int32, @name : String, @email : String)
  end
end

@[LF::DI::Service]
class SomeService
end
# Create a router
router = LF::Router.new

# Simple GET route
router.get("/") do |ctx, _params|
  ctx.response.content_type = "text/plain"
  ctx.response.print "Welcome to Opal!"
end

# Route with single parameter
router.get("/users/:id") do |ctx, params|
  user_id = params["id"]
  ctx.response.content_type = "text/plain"
  ctx.response.print "User ID: #{user_id}"
end

# Route with multiple parameters
router.get("/api/posts/:post_id/comments/:comment_id") do |ctx, params|
  post_id = params["post_id"]
  comment_id = params["comment_id"]

  ctx.response.content_type = "text/plain"
  ctx.response.print "Post: #{post_id}, Comment: #{comment_id}"
end

class Blaf
  @[LF::APIRoute::Get("/blaf")]
  def self.index
    "Hello, world!"
  end
end

class TestRoute
  include LF::APIRoute

  @[LF::APIRoute::Get("/test/:id")]
  def get_test(id : Int32)
    User.new(
      id: id,
      name: "John Doe",
      email: "john@example.com"
    )
  end
end

# JSON response
router.get("/api/users/:id") do |ctx, params|
  user = User.new(
    id: params["id"].to_i,
    name: "John Doe",
    email: "john@example.com"
  )

  ctx.response.content_type = "application/json"
  user.to_json(ctx.response)
end

# POST route
router.post("/api/users") do |ctx, _params|
  # In real app, you'd parse request body here
  ctx.response.status = HTTP::Status::CREATED
  ctx.response.content_type = "text/plain"
  ctx.response.print "User created"
end

# PUT route
router.put("/api/users/:id") do |ctx, params|
  user_id = params["id"]
  ctx.response.content_type = "text/plain"
  ctx.response.print "User #{user_id} updated"
end

# DELETE route
router.delete("/api/users/:id") do |ctx, params|
  user_id = params["id"]
  ctx.response.content_type = "text/plain"
  ctx.response.print "User #{user_id} deleted"
end

# Using LFApi wrapper
app = LF::LFApi.new do |r|
  r.get("/hello") do |ctx, _params|
    ctx.response.content_type = "text/plain"
    ctx.response.print "Hello from Opal!"
  end

  r.get("/hello/:name") do |ctx, params|
    ctx.response.content_type = "text/plain"
    ctx.response.print "Hello, #{params["name"]}!"
  end
end
test_route = TestRoute.new
test_route.setup_routes(router)
# Create HTTP server
server = HTTP::Server.new([
  HTTP::LogHandler.new,
  router,  # or use 'app' for LFApi wrapper
  app
])

address = server.bind_tcp 9999
puts "🚀 Server started at http://#{address}"
puts "\nAvailable routes:"
puts "  GET  /                               - Welcome message"
puts "  GET  /users/:id                      - Get user by ID"
puts "  GET  /api/posts/:post_id/comments/:comment_id"
puts "  GET  /api/users/:id                  - Get user JSON"
puts "  POST /api/users                      - Create user"
puts "  PUT  /api/users/:id                  - Update user"
puts "  DELETE /api/users/:id                - Delete user"
puts "\nPress Ctrl+C to stop"
server.listen
