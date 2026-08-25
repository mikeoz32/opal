require "../../../src/opal"

class InvalidWebSocketController
  include LF::HTTP::Controller

  @[LF::HTTP::Controller::WebSocket("/invalid-ws")]
  def echo(ws : HTTP::WebSocket) : String
    "invalid"
  end
end

root = LF::DI::DefaultContainer.new
router = LF::HTTP::Router.new
InvalidWebSocketController.setup_routes(router, root)
