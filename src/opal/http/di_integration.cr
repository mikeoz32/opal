require "http/server"
require "../di"
require "./websocket_connection_registry"

class HTTP::Server::Context
  property dependency_scope : LF::DI::Container?
  property websocket_upgrade : LF::HTTP::WebSocketUpgrade?
  property dependency_scope_initializer : Proc(LF::DI::Container, Nil)?
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
