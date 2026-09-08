require "../../../src/opal/microservices/crabbit_streams"

alias MS = LF::Microservices

@[MS::StreamEventContract(
  namespace: "shop",
  service: "orders",
  contract_version: 1,
  event: "created",
  schema_version: 1,
)]
struct InvalidTopologyEvent
  include JSON::Serializable
  include MS::StreamEvent
end

class NotAStreamTopology
end

@[MS::StreamHandler(topology: NotAStreamTopology, subscription: "projection")]
class InvalidTopologyProjection
  include MS::StreamProjection

  def handle(event : InvalidTopologyEvent, context : MS::StreamContext) : Nil
  end
end

MS.compile_stream_handlers(InvalidTopologyProjection)
