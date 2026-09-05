# WebSockets

Opal routes native Crystal WebSockets alongside HTTP routes. A registered path
cannot be both an HTTP and a WebSocket route, which keeps the upgrade boundary
unambiguous.

## Router style

```crystal
router.ws("/echo") do |socket, params|
  while message = socket.receive?
    socket.send("#{params["room"]?}: #{message}")
  end
end
```

Use `Router#ws` for a small protocol. Use a controller action for DI and the
same route-discovery model as the HTTP API:

```crystal
class ChatSocket
  include LF::HTTP::Controller

  @[LF::HTTP::Controller::WebSocket("/chat")]
  def chat(socket : HTTP::WebSocket) : Nil
    socket.on_message { |message| socket.send("echo: #{message}") }
  end
end
```

Do not combine `on_message` with a manual `receive?` loop unless processing the
same input twice is intentional.

## Authentication and scopes

HTTP controller guards run before upgrade, so the same direct
`@[LF::HTTP::UseGuards(...)]` annotation protects both HTTP and socket routes.
The security middleware authenticates the handshake; an accepted connection
gets its own DI scope. Revalidate authorization for resource-specific messages
inside the handler.

For a server-rendered UI over a managed socket protocol, use
[LiveView](../live-view.md) rather than inventing a page protocol on top of raw
WebSockets.
