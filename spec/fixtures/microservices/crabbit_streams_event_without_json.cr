require "../../../src/opal/microservices/crabbit_streams"

@[LF::Microservices::StreamEventContract(
  namespace: "shop",
  service: "orders",
  contract_version: 1,
  event: "created",
  schema_version: 1,
)]
struct InvalidStreamEvent
  include LF::Microservices::StreamEvent
end

InvalidStreamEvent.stream_event_identity
