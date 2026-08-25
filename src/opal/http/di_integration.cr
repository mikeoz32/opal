require "http/server"
require "../di"

class HTTP::Server::Context
  property dependency_scope : LF::DI::Container?
end
