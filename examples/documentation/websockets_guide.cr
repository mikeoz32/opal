require "opal"

# --8<-- [start:router]
router = LF::HTTP::Router.new
router.ws("/echo/:room") do |socket, params|
  while message = socket.receive?
    socket.send("#{params["room"]}: #{message}")
  end
end

# --8<-- [end:router]

# --8<-- [start:controller]
class ChatSocket
  include LF::HTTP::Controller

  @[LF::HTTP::Controller::WebSocket("/chat")]
  def chat(socket : HTTP::WebSocket) : Nil
    socket.on_message { |message| socket.send("echo: #{message}") }
  end
end

root = LF::DI::DefaultContainer.new
app = LF::HTTP::App.new do |app_router|
  ChatSocket.setup_routes(app_router, root)
end
# --8<-- [end:controller]
