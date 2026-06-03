require "../src/opal"

class User
  include JSON::Serializable

  property id : Int32
  property name : String

  def initialize(@id : Int32, @name : String)
  end
end

router = LF::Router.new

router.get("/") do |ctx, _params|
  ctx.response.content_type = "text/plain"
  ctx.response.print "Welcome to Opal"
end

router.get("/health") do |ctx, _params|
  ctx.response.content_type = "application/json"
  ctx.response.print %({"status":"ok"})
end

router.get("/users/:id") do |ctx, params|
  user = User.new(params["id"].to_i, "User #{params["id"]}")
  ctx.response.content_type = "application/json"
  user.to_json(ctx.response)
end

router.post("/users") do |ctx, _params|
  ctx.response.status = HTTP::Status::CREATED
  ctx.response.print "created"
end

server = HTTP::Server.new([
  HTTP::LogHandler.new,
  router,
])

address = server.bind_tcp(8080)
puts "Listening on http://#{address}"
puts "Routes:"
puts "  GET  /"
puts "  GET  /health"
puts "  GET  /users/:id"
puts "  POST /users"

server.listen
