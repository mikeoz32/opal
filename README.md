# Opal

A high-performance HTTP router and lightweight API framework for Crystal.

A high-performance HTTP router for Crystal with Trie-based route matching and URL parameter support.

## Features

- ⚡ **Fast Route Matching**: O(k) complexity where k is the path length (not dependent on number of routes)
- 🎯 **URL Parameters**: Dynamic path segments using `:param_name` syntax
- 🔀 **Multiple Parameters**: Support for multiple params per route
- 🌐 **HTTP Method Routing**: GET, POST, PUT, DELETE, PATCH on the same path
- ✅ **Automatic Status Codes**: 404 Not Found, 405 Method Not Allowed
- 📊 **Priority Matching**: Exact paths take priority over parameter matches
- 🔧 **Zero Dependencies**: Uses only Crystal stdlib

## Architecture

The router uses a **Radix Tree (Trie)** data structure for efficient route matching:

1. **Trie Module**: Core radix tree implementation
   - `Node`: Represents a URL segment in the tree
   - `MatchResult`: Contains matched node and extracted parameters
   - `Handler`: Proc that receives context and route parameters

2. **LF Module**: HTTP routing layer
   - `Router`: Main routing class with Trie-based matching
   - `LFApi`: HTTP::Handler wrapper for middleware integration
   - Convenience methods: `get()`, `post()`, `put()`, `delete()`, `patch()`

## Installation

Add this to your application's `shard.yml`:

```yaml
dependencies:
  ametist:
    github: your-username/opal
```

## Usage

### Basic Router

```crystal
require "opal"

router = LF::Router.new

# Simple route
router.get("/") do |ctx, params|
  ctx.response.content_type = "text/plain"
  ctx.response.print "Welcome!"
end

# Route with parameter
router.get("/users/:id") do |ctx, params|
  user_id = params["id"]
  ctx.response.print "User ID: #{user_id}"
end

# Multiple parameters
router.get("/posts/:post_id/comments/:comment_id") do |ctx, params|
  ctx.response.print "Post: #{params["post_id"]}, Comment: #{params["comment_id"]}"
end

# Different HTTP methods
router.post("/users") do |ctx, params|
  ctx.response.status = HTTP::Status::CREATED
  ctx.response.print "User created"
end

router.delete("/users/:id") do |ctx, params|
  ctx.response.print "User #{params["id"]} deleted"
end

# Start server
server = HTTP::Server.new([router])
server.bind_tcp(8080)
server.listen
```

### Using LFApi Wrapper

```crystal
app = LF::LFApi.new do |router|
  router.get("/hello") do |ctx, params|
    ctx.response.print "Hello World!"
  end
  
  router.get("/hello/:name") do |ctx, params|
    ctx.response.print "Hello, #{params["name"]}!"
  end
end

# Use as HTTP::Handler
server = HTTP::Server.new([HTTP::LogHandler.new, app])
server.bind_tcp(8080)
server.listen
```

### JSON Responses

```crystal
class User
  include JSON::Serializable
  property id : Int32
  property name : String
end

router.get("/api/users/:id") do |ctx, params|
  user = User.new(
    id: params["id"].to_i,
    name: "John Doe"
  )
  
  ctx.response.content_type = "application/json"
  user.to_json(ctx.response)
end
```

### All HTTP Methods

```crystal
router.get("/resource/:id") { |ctx, params| ... }
router.post("/resource") { |ctx, params| ... }
router.put("/resource/:id") { |ctx, params| ... }
router.patch("/resource/:id") { |ctx, params| ... }
router.delete("/resource/:id") { |ctx, params| ... }
```

## Route Matching Rules

1. **Exact matches take priority** over parameter matches:
   ```crystal
   router.get("/users/list") { ... }  # Matches /users/list
   router.get("/users/:id") { ... }    # Matches /users/123, /users/456, etc.
   ```

2. **Parameters must have values** - empty segments won't match:
   ```crystal
   # /users/:id matches /users/123
   # /users/:id does NOT match /users/ or /users
   ```

3. **Multiple methods on same path** are supported:
   ```crystal
   router.get("/data") { ... }
   router.post("/data") { ... }
   # GET /data returns 200, POST /data returns 200
   # PUT /data returns 405 Method Not Allowed
   ```

## Performance

The Trie-based approach provides **O(k)** lookup time where k is the path length:

- **Not affected** by the number of routes in your application
- **Constant time** for each path segment
- **Memory efficient** due to prefix compression
- **Fast parameter extraction** during traversal

Compared to linear scanning (O(n) where n = number of routes), this is significantly faster for applications with many routes.

## HTTP Status Codes

The router automatically handles:

- `200 OK` - Route found and handler executed
- `404 Not Found` - No matching route
- `405 Method Not Allowed` - Route exists but method not registered

## Testing

```crystal
crystal spec spec/opal_spec.cr
```

## Example

See `examples/router_example.cr` for a complete working example.

```bash
crystal run examples/router_example.cr
```

## API Reference

### Trie::Node

```crystal
# Add a route to the tree
add_route(path : String, handler : Handler, methods : Set(String) = Set{"GET"})

# Search for a matching route
search(path : String) : MatchResult
```

### LF::Router

```crystal
# HTTP method helpers
get(path : String, &handler : HTTP::Server::Context, Hash(String, String) -> Nil)
post(path : String, &handler : HTTP::Server::Context, Hash(String, String) -> Nil)
put(path : String, &handler : HTTP::Server::Context, Hash(String, String) -> Nil)
delete(path : String, &handler : HTTP::Server::Context, Hash(String, String) -> Nil)
patch(path : String, &handler : HTTP::Server::Context, Hash(String, String) -> Nil)

# Generic add method
add(path : String, methods : Set(String) = Set{"GET"}, &handler)

# Call method (implements HTTP::Handler)
call(context : HTTP::Server::Context)
```

### LF::LFApi

```crystal
# Initialize with block
LFApi.new(&block : Router -> Nil)

# Call method (implements HTTP::Handler)
call(context : HTTP::Server::Context)
```

## Future Enhancements

Potential future features (not yet implemented):

- Wildcard routes (`/files/*filepath`)
- Route groups with prefixes
- Middleware support per route
- Query string parameter helpers
- Request body parsing helpers
- FastAPI-style automatic parameter injection (experimental)

## License

See LICENSE file.

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Run tests (`crystal spec`)
4. Commit your changes (`git commit -am 'Add some feature'`)
5. Push to the branch (`git push origin my-new-feature`)
6. Create a new Pull Request