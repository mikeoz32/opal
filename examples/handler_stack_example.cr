require "../src/opal"

class RequestIdHandler
  include HTTP::Handler

  def call(context)
    request_id = UUID.random.to_s
    context.response.headers["X-Request-ID"] = request_id
    call_next(context)
  end
end

app = LF::LFApi.new do |router|
  router.get("/hello") do |ctx, _params|
    ctx.response.content_type = "text/plain"
    ctx.response.print "Hello from handler stack"
  end

  router.get("/users/:id") do |ctx, params|
    ctx.response.print "user=#{params["id"]}"
  end
end

server = HTTP::Server.new([
  HTTP::LogHandler.new,
  RequestIdHandler.new,
  app,
])

address = server.bind_tcp(8082)
puts "Listening on http://#{address}"
puts "Routes:"
puts "  GET /hello"
puts "  GET /users/:id"

server.listen
