require "../../../src/opal/microservices/crabbit_streams"

alias MS = LF::Microservices

@[MS::StreamEventContract(
  namespace: "shop",
  service: "orders",
  contract_version: 1,
  event: "created",
  schema_version: 1,
)]
struct DuplicateStreamEvent
  include JSON::Serializable
  include MS::StreamEvent
end

class DuplicateStream
  include MS::StreamTopology
  stream "duplicate"
end

@[MS::StreamHandler(topology: DuplicateStream, subscription: "projection")]
class FirstDuplicateProjection
  include MS::StreamProjection

  def handle(event : DuplicateStreamEvent, context : MS::StreamContext) : Nil
  end
end

@[MS::StreamHandler(topology: DuplicateStream, subscription: "projection")]
class SecondDuplicateProjection
  include MS::StreamProjection

  def handle(event : DuplicateStreamEvent, context : MS::StreamContext) : Nil
  end
end

MS.compile_stream_handlers(FirstDuplicateProjection, SecondDuplicateProjection)
