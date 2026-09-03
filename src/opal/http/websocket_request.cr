require "http/request"

module LF::HTTP::WebSocketRequest
  extend self

  def upgrade?(request : ::HTTP::Request) : Bool
    return false unless upgrade = request.headers["Upgrade"]?
    return false unless upgrade.compare("websocket", case_insensitive: true) == 0

    request.headers.includes_word?("Connection", "Upgrade")
  end
end
