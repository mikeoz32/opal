require "http/server"
require "../di"
require "./websocket_connection_registry"

class HTTP::Server::Context
  property dependency_scope : LF::DI::Container?
  property websocket_upgrade : LF::HTTP::WebSocketUpgrade?
end

module LF::HTTP
  class WebSocketUpgrade
    getter registry : WebSocketConnectionRegistry?
    getter io : IO
    property connection : WebSocketConnectionRegistry::Connection?

    def initialize(@io, @registry = nil)
    end
  end
end
