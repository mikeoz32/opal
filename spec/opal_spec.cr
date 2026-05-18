require "./spec_helper"
require "../src/opal"
require "http/client"

class JsonModel
  include JSON::Serializable

  property id : Int32
  property name : String

  def initialize(@id : Int32, @name : String)
  end
end

class TestResourceForDI
  include LF::APIRoute

  @[LF::APIRoute::Get("/test")]
  def test_endpoint(name : String)
    "Hello #{name}"
  end
end

class TestAPIWithParams
  include LF::APIRoute

  @[LF::APIRoute::Get("/users/:id")]
  def get_user(id : Int32)
    "User #{id}"
  end

  @[LF::APIRoute::Get("/items/:item_id")]
  def get_item(item_id : Int64)
    "Item #{item_id}"
  end

  @[LF::APIRoute::Get("/products/:product_id")]
  def get_product(product_id : UUID)
    "Product #{product_id}"
  end

  @[LF::APIRoute::Get("/settings/:key")]
  def get_setting(key : String, enabled : Bool)
    "Setting #{key} is #{enabled}"
  end
end

class TestResourceJsonResponse
  include LF::APIRoute

  @[LF::APIRoute::Get("/json-response")]
  def json_response
    LF::JSONResponse.create(JsonModel.new(1, "ok"))
  end
end

describe "Trie" do
  describe "Node" do
    it "adds and searches exact routes" do
      t = Trie::Node.new
      dummy_handler = ->(ctx : HTTP::Server::Context, params : Hash(String, String)) { }

      t.add_route("/hello", dummy_handler)
      t.add_route("/hi", dummy_handler)
      t.add_route("/hi/user", dummy_handler)

      result = t.search("/hello")
      result.node.should_not be_nil
      result.params.should be_empty

      result = t.search("/hi")
      result.node.should_not be_nil
      result.params.should be_empty

      result = t.search("/hi/user")
      result.node.should_not be_nil
      result.params.should be_empty
    end

    it "matches routes with single parameter" do
      t = Trie::Node.new
      dummy_handler = ->(ctx : HTTP::Server::Context, params : Hash(String, String)) { }

      t.add_route("/users/:id", dummy_handler)

      result = t.search("/users/42")
      result.node.should_not be_nil
      result.params["id"].should eq("42")

      result = t.search("/users/john")
      result.node.should_not be_nil
      result.params["id"].should eq("john")
    end

    it "matches routes with multiple parameters" do
      t = Trie::Node.new
      dummy_handler = ->(ctx : HTTP::Server::Context, params : Hash(String, String)) { }

      t.add_route("/api/posts/:post_id/comments/:comment_id", dummy_handler)

      result = t.search("/api/posts/42/comments/7")
      result.node.should_not be_nil
      result.params["post_id"].should eq("42")
      result.params["comment_id"].should eq("7")

      result = t.search("/api/posts/hello-world/comments/99")
      result.node.should_not be_nil
      result.params["post_id"].should eq("hello-world")
      result.params["comment_id"].should eq("99")
    end

    it "returns nil for non-existent routes" do
      t = Trie::Node.new
      dummy_handler = ->(ctx : HTTP::Server::Context, params : Hash(String, String)) { }

      t.add_route("/hello", dummy_handler)

      result = t.search("/notfound")
      result.node.should be_nil
    end

    it "prioritizes exact matches over parameter matches" do
      t = Trie::Node.new
      dummy_handler1 = ->(ctx : HTTP::Server::Context, params : Hash(String, String)) {
        ctx.response.print "exact"
      }
      dummy_handler2 = ->(ctx : HTTP::Server::Context, params : Hash(String, String)) {
        ctx.response.print "param"
      }

      t.add_route("/users/list", dummy_handler1)
      t.add_route("/users/:id", dummy_handler2)

      result = t.search("/users/list")
      result.node.should_not be_nil
      result.params.should be_empty

      result = t.search("/users/123")
      result.node.should_not be_nil
      result.params["id"].should eq("123")
    end
  end
end

describe "LF::Router" do
  it "routes GET requests correctly" do
    router = LF::Router.new

    router.get("/hello") do |ctx, _params|
      ctx.response.content_type = "text/plain"
      ctx.response.print "Hello World!"
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/hello")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    router.call(context)
    response.close

    result_output = io.to_s
    body = result_output.split("\r\n\r\n", 2)[1]
    body.should eq("Hello World!")
    response.status.should eq(HTTP::Status::OK)
  end

  it "extracts route parameters" do
    router = LF::Router.new

    router.get("/users/:id") do |ctx, params|
      ctx.response.content_type = "text/plain"
      ctx.response.print "User ID: #{params["id"]}"
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/users/123")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    router.call(context)
    response.close

    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("User ID: 123")
  end

  it "extracts multiple parameters" do
    router = LF::Router.new

    router.get("/api/posts/:post_id/comments/:comment_id") do |ctx, params|
      ctx.response.content_type = "text/plain"
      ctx.response.print "Post #{params["post_id"]}, Comment #{params["comment_id"]}"
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/api/posts/42/comments/7")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    router.call(context)
    response.close

    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("Post 42, Comment 7")
  end

  it "supports different HTTP methods on same path" do
    router = LF::Router.new

    router.get("/data") do |ctx, _params|
      ctx.response.print "GET data"
    end

    router.post("/data") do |ctx, _params|
      ctx.response.print "POST data"
    end

    # Test GET
    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/data")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)
    router.call(context)
    response.close
    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("GET data")

    # Test POST
    io = IO::Memory.new
    request = HTTP::Request.new("POST", "/data")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)
    router.call(context)
    response.close
    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("POST data")
  end

  it "returns 404 for non-existent routes" do
    router = LF::Router.new

    router.get("/hello") do |ctx, _params|
      ctx.response.print "Hello"
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/notfound")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    router.call(context)
    response.close

    response.status.should eq(HTTP::Status::NOT_FOUND)
  end

  it "returns 405 for wrong HTTP method" do
    router = LF::Router.new

    router.post("/data") do |ctx, _params|
      ctx.response.print "POST only"
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/data")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    router.call(context)
    response.close

    response.status.should eq(HTTP::Status::METHOD_NOT_ALLOWED)
  end

  it "supports all HTTP method convenience methods" do
    router = LF::Router.new

    router.get("/get") { |ctx, _| ctx.response.print "GET" }
    router.post("/post") { |ctx, _| ctx.response.print "POST" }
    router.put("/put") { |ctx, _| ctx.response.print "PUT" }
    router.delete("/delete") { |ctx, _| ctx.response.print "DELETE" }
    router.patch("/patch") { |ctx, _| ctx.response.print "PATCH" }

    methods = ["GET", "POST", "PUT", "DELETE", "PATCH"]
    methods.each do |method|
      io = IO::Memory.new
      request = HTTP::Request.new(method, "/#{method.downcase}")
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)
      router.call(context)
      response.close
      body = io.to_s.split("\r\n\r\n", 2)[1]
      body.should eq(method)
    end
  end
end

describe "LF::LFApi" do
  it "works as HTTP::Handler" do
    app = LF::LFApi.new do |router|
      router.get("/hello") do |ctx, _params|
        ctx.response.content_type = "text/plain"
        ctx.response.print "Hello from Opal!"
      end
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/hello")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    app.call(context)
    response.close

    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("Hello from Opal!")
  end

  it "handles JSON responses" do
    app = LF::LFApi.new do |router|
      router.get("/json") do |ctx, _params|
        ctx.response.content_type = "application/json"
        JsonModel.new(1, "John").to_json(ctx.response)
      end
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/json")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    app.call(context)
    response.close

    result_output = io.to_s
    body = if result_output.includes?("\r\n\r\n")
      result_output.split("\r\n\r\n", 2)[1]
    else
      result_output
    end

    # Just check the body contains the expected JSON structure
    body.should contain("\"id\"")
    body.should contain("\"name\"")
    body.should contain("John")
  end

  it "returns 400 for BadRequest" do
    app = LF::LFApi.new do |router|
      router.get("/bad") do
        raise LF::BadRequest.new("bad input")
      end
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/bad")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    app.call(context)
    response.close

    response.status.should eq(HTTP::Status::BAD_REQUEST)
    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("bad input")
  end

  it "returns 404 for NotFound" do
    app = LF::LFApi.new do |router|
      router.get("/missing") do
        raise LF::NotFound.new("missing")
      end
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/missing")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    app.call(context)
    response.close

    response.status.should eq(HTTP::Status::NOT_FOUND)
    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("missing")
  end

  it "returns 500 for unexpected errors" do
    app = LF::LFApi.new do |router|
      router.get("/boom") do
        raise "boom"
      end
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/boom")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    app.call(context)
    response.close

    response.status.should eq(HTTP::Status::INTERNAL_SERVER_ERROR)
    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("Internal Server Error")
  end
end

describe "LF::APIRoute" do
  it "returns 500 when DI context is not initialized (missing middleware)" do
    # Create API route without DatabaseInjector middleware
    app = LF::LFApi.new do |router|
      TestResourceForDI.new.setup_routes(router)
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/test")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)
    # Note: context.state is nil here (no middleware set it)

    app.call(context)
    response.close

    response.status.should eq(HTTP::Status::INTERNAL_SERVER_ERROR)
    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("DI context not initialized")
  end

  it "renders JSONResponse return values" do
    app = LF::LFApi.new do |router|
      TestResourceJsonResponse.new.setup_routes(router)
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/json-response")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    app.call(context)
    response.close

    response.status.should eq(HTTP::Status::OK)
    parsed = HTTP::Client::Response.from_io(IO::Memory.new(io.to_s))
    payload = JSON.parse(parsed.body)
    payload["id"].as_i.should eq(1)
    payload["name"].as_s.should eq("ok")
  end
end

describe "LF Parameter Binding and Type Coercion" do
  describe "Hash#to_t" do
    it "converts to Int32 successfully" do
      params = {"id" => "42"}
      result = params.to_t("id", Int32)
      result.should eq(42)
    end

    it "raises BadRequest for invalid Int32" do
      params = {"id" => "abc"}
      expect_raises(LF::BadRequest, "Invalid value for parameter 'id': expected Int32") do
        params.to_t("id", Int32)
      end
    end

    it "converts to Int64 successfully" do
      params = {"big_id" => "9223372036854775807"}
      result = params.to_t("big_id", Int64)
      result.should eq(9223372036854775807_i64)
    end

    it "raises BadRequest for invalid Int64" do
      params = {"big_id" => "not_a_number"}
      expect_raises(LF::BadRequest, "Invalid value for parameter 'big_id': expected Int64") do
        params.to_t("big_id", Int64)
      end
    end

    it "converts to Float32 successfully" do
      params = {"price" => "19.99"}
      result = params.to_t("price", Float32).as(Float32)
      result.should be_close(19.99_f32, 0.01)
    end

    it "raises BadRequest for invalid Float32" do
      params = {"price" => "not_a_float"}
      expect_raises(LF::BadRequest, "Invalid value for parameter 'price': expected Float32") do
        params.to_t("price", Float32)
      end
    end

    it "converts to Float64 successfully" do
      params = {"precise" => "3.141592653589793"}
      result = params.to_t("precise", Float64).as(Float64)
      result.should be_close(3.141592653589793, 0.000001)
    end

    it "raises BadRequest for invalid Float64" do
      params = {"precise" => "xyz"}
      expect_raises(LF::BadRequest, "Invalid value for parameter 'precise': expected Float64") do
        params.to_t("precise", Float64)
      end
    end

    it "converts to Bool successfully with 'true'" do
      params = {"active" => "true"}
      result = params.to_t("active", Bool)
      result.should eq(true)
    end

    it "converts to Bool successfully with 'false'" do
      params = {"active" => "false"}
      result = params.to_t("active", Bool)
      result.should eq(false)
    end

    it "converts to Bool successfully with '1'" do
      params = {"active" => "1"}
      result = params.to_t("active", Bool)
      result.should eq(true)
    end

    it "converts to Bool successfully with '0'" do
      params = {"active" => "0"}
      result = params.to_t("active", Bool)
      result.should eq(false)
    end

    it "converts to Bool successfully with 'yes'" do
      params = {"active" => "yes"}
      result = params.to_t("active", Bool)
      result.should eq(true)
    end

    it "converts to Bool successfully with 'no'" do
      params = {"active" => "no"}
      result = params.to_t("active", Bool)
      result.should eq(false)
    end

    it "raises BadRequest for invalid Bool" do
      params = {"active" => "maybe"}
      expect_raises(LF::BadRequest, "Invalid value for parameter 'active': expected Bool") do
        params.to_t("active", Bool)
      end
    end

    it "converts to UUID successfully" do
      params = {"request_id" => "550e8400-e29b-41d4-a716-446655440000"}
      result = params.to_t("request_id", UUID)
      result.should eq(UUID.new("550e8400-e29b-41d4-a716-446655440000"))
    end

    it "raises BadRequest for invalid UUID" do
      params = {"request_id" => "not-a-uuid"}
      expect_raises(LF::BadRequest, "Invalid value for parameter 'request_id': expected UUID") do
        params.to_t("request_id", UUID)
      end
    end

    it "converts to String successfully" do
      params = {"name" => "John Doe"}
      result = params.to_t("name", String)
      result.should eq("John Doe")
    end

    it "raises BadRequest for missing parameter" do
      params = {} of String => String
      expect_raises(LF::BadRequest, "Missing required parameter 'id'") do
        params.to_t("id", Int32)
      end
    end
  end

  describe "APIRoute parameter binding" do
    it "returns 200 for valid Int32 parameter" do
      app = LF::LFApi.new do |router|
        TestAPIWithParams.new.setup_routes(router)
      end

      io = IO::Memory.new
      request = HTTP::Request.new("GET", "/users/123")
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)
      context.state = LF::DI::AnnotationApplicationContext.new

      app.call(context)
      response.close

      response.status.should eq(HTTP::Status::OK)
      body = io.to_s.split("\r\n\r\n", 2)[1]
      body.should eq("User 123")
    end

    it "returns 400 for invalid Int32 parameter" do
      app = LF::LFApi.new do |router|
        TestAPIWithParams.new.setup_routes(router)
      end

      io = IO::Memory.new
      request = HTTP::Request.new("GET", "/users/abc")
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)
      context.state = LF::DI::AnnotationApplicationContext.new

      app.call(context)
      response.close

      response.status.should eq(HTTP::Status::BAD_REQUEST)
      body = io.to_s.split("\r\n\r\n", 2)[1]
      body.should eq("Invalid value for parameter 'id': expected Int32")
    end

    it "returns 200 for valid Int64 parameter" do
      app = LF::LFApi.new do |router|
        TestAPIWithParams.new.setup_routes(router)
      end

      io = IO::Memory.new
      request = HTTP::Request.new("GET", "/items/9223372036854775807")
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)
      context.state = LF::DI::AnnotationApplicationContext.new

      app.call(context)
      response.close

      response.status.should eq(HTTP::Status::OK)
      body = io.to_s.split("\r\n\r\n", 2)[1]
      body.should eq("Item 9223372036854775807")
    end

    it "returns 200 for valid UUID parameter" do
      app = LF::LFApi.new do |router|
        TestAPIWithParams.new.setup_routes(router)
      end

      io = IO::Memory.new
      request = HTTP::Request.new("GET", "/products/550e8400-e29b-41d4-a716-446655440000")
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)
      context.state = LF::DI::AnnotationApplicationContext.new

      app.call(context)
      response.close

      response.status.should eq(HTTP::Status::OK)
      body = io.to_s.split("\r\n\r\n", 2)[1]
      body.should eq("Product 550e8400-e29b-41d4-a716-446655440000")
    end

    it "returns 400 for invalid UUID parameter" do
      app = LF::LFApi.new do |router|
        TestAPIWithParams.new.setup_routes(router)
      end

      io = IO::Memory.new
      request = HTTP::Request.new("GET", "/products/not-a-uuid")
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)
      context.state = LF::DI::AnnotationApplicationContext.new

      app.call(context)
      response.close

      response.status.should eq(HTTP::Status::BAD_REQUEST)
      body = io.to_s.split("\r\n\r\n", 2)[1]
      body.should eq("Invalid value for parameter 'product_id': expected UUID")
    end

    it "returns 200 for valid Bool parameter (true)" do
      app = LF::LFApi.new do |router|
        TestAPIWithParams.new.setup_routes(router)
      end

      io = IO::Memory.new
      request = HTTP::Request.new("GET", "/settings/notifications?enabled=true")
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)
      context.state = LF::DI::AnnotationApplicationContext.new

      app.call(context)
      response.close

      response.status.should eq(HTTP::Status::OK)
      body = io.to_s.split("\r\n\r\n", 2)[1]
      body.should eq("Setting notifications is true")
    end

    it "returns 200 for valid Bool parameter (false)" do
      app = LF::LFApi.new do |router|
        TestAPIWithParams.new.setup_routes(router)
      end

      io = IO::Memory.new
      request = HTTP::Request.new("GET", "/settings/notifications?enabled=false")
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)
      context.state = LF::DI::AnnotationApplicationContext.new

      app.call(context)
      response.close

      response.status.should eq(HTTP::Status::OK)
      body = io.to_s.split("\r\n\r\n", 2)[1]
      body.should eq("Setting notifications is false")
    end

    it "returns 400 for invalid Bool parameter" do
      app = LF::LFApi.new do |router|
        TestAPIWithParams.new.setup_routes(router)
      end

      io = IO::Memory.new
      request = HTTP::Request.new("GET", "/settings/notifications?enabled=maybe")
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)
      context.state = LF::DI::AnnotationApplicationContext.new

      app.call(context)
      response.close

      response.status.should eq(HTTP::Status::BAD_REQUEST)
      body = io.to_s.split("\r\n\r\n", 2)[1]
      body.should eq("Invalid value for parameter 'enabled': expected Bool")
    end

    it "returns 400 for missing required parameter" do
      app = LF::LFApi.new do |router|
        TestAPIWithParams.new.setup_routes(router)
      end

      io = IO::Memory.new
      request = HTTP::Request.new("GET", "/settings/notifications")
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)
      context.state = LF::DI::AnnotationApplicationContext.new

      app.call(context)
      response.close

      response.status.should eq(HTTP::Status::BAD_REQUEST)
      body = io.to_s.split("\r\n\r\n", 2)[1]
      body.should eq("Missing required parameter 'enabled'")
    end
  end
end
