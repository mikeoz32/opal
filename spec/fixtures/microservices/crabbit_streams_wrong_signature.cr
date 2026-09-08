require "../../../src/opal/microservices/crabbit_streams"

alias MS = LF::Microservices

@[MS::StreamEventContract(
  namespace: "shop",
  service: "orders",
  contract_version: 1,
  event: "created",
  schema_version: 1,
)]
struct WrongSignatureEvent
  include JSON::Serializable
  include MS::StreamEvent
end

class WrongSignatureStream
  include MS::StreamTopology
  stream "wrong-signature"
end

@[MS::StreamHandler(topology: WrongSignatureStream, subscription: "projection")]
class WrongSignatureProjection
  include MS::StreamProjection

  def handle(event : WrongSignatureEvent) : Nil
  end
end

MS.compile_stream_handlers(WrongSignatureProjection)
