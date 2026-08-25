require "http/server"
require "../di"
require "./websocket_connection_registry"

class HTTP::Server::Context
  property dependency_scope : LF::DI::Container?
  property websocket_connection_registry : LF::HTTP::WebSocketConnectionRegistry?
  property websocket_connection : LF::HTTP::WebSocketConnectionRegistry::Connection?
  property websocket_io : IO?
end
