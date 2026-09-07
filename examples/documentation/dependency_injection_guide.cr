require "opal"

# --8<-- [start:service]
@[LF::DI::Service]
class Clock
  def now : Time
    Time.utc
  end
end

root = LF::DI::DefaultContainer.new
root.register(LF::DI::ServiceConfiguration.new)

# --8<-- [end:service]

# --8<-- [start:provider]
class AppBeans
  include LF::DI::BeanConfiguration

  @[LF::DI::Bean(name: "request_id", scope: "request")]
  def request_id : String
    UUID.random.to_s
  end
end

root.register(AppBeans.new)
# --8<-- [end:provider]

app = LF::HTTP::App.new { |_router| }

# --8<-- [start:handlers]
server = HTTP::Server.new([
  LF::HTTP::DI::WebSocketScopeHandler.new(root),
  LF::HTTP::DI::RequestScopeHandler.new(root),
  app,
])
# --8<-- [end:handlers]
