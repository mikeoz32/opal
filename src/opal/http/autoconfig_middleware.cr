require "http/server"

module LF::HTTP
  # A named, opt-in middleware contribution for HTTP autoconfiguration.
  #
  # The HTTP extension deliberately has one explicit contribution point rather
  # than scanning arbitrary handlers. Optional packages register it under the
  # documented `http_autoconfig_middleware` bean name.
  module AutoConfigMiddleware
    include ::HTTP::Handler
  end
end
