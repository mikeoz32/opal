require "../../../src/opal/autoconfig/microservices/crabbit_streams"

alias MS = LF::Microservices

@[MS::StreamEventContract(
  namespace: "shop",
  service: "orders",
  contract_version: 1,
  event: "order_created",
  schema_version: 1,
)]
struct StreamOrderCreated
  include JSON::Serializable
  include MS::StreamEvent

  getter order_id : String

  def initialize(@order_id : String)
  end
end

class OrdersEventStream
  include MS::StreamTopology

  super_stream "orders", 3
end

@[LF::DI::Service]
@[MS::StreamHandler(
  topology: OrdersEventStream,
  subscription: "orders_projection",
)]
class ProjectOrderCreated
  include MS::StreamProjection

  def handle(event : StreamOrderCreated, context : MS::StreamContext) : Nil
    event.order_id
    context.stream_metadata
  end
end

@[LF::Application]
@[LF::AutoConfig::CrabbitStreams(
  topologies: [OrdersEventStream],
  handlers: [ProjectOrderCreated],
)]
class CrabbitStreamsApplication
end

STREAM_HANDLERS = MS.compile_stream_handlers(ProjectOrderCreated)

typeof(CrabbitStreamsApplication.bootstrap_stream_worker)
typeof(CrabbitStreamsApplication.run_stream_worker)

if ENV["OPAL_EXERCISE_CRABBIT_STREAMS"]?
  environment = Crabbit::Environment.connect
  publisher = MS::StreamPublisher.new(environment, "orders-api")
  receipt = publisher.publish(
    OrdersEventStream,
    StreamOrderCreated.new("order-1"),
    routing_key: "order-1",
  )
  receipt.await

  identity = StreamOrderCreated.stream_event_identity
  envelope = MS::EventEnvelope.new(
    UUID.random,
    identity.source,
    identity.event,
    identity.schema_version,
    Time.utc,
    payload: JSON.parse(StreamOrderCreated.new("order-2").to_json),
  )
  publisher
    .publish_envelope(
      OrdersEventStream.stream_definition,
      envelope,
      routing_key: "order-2",
    )
    .await
  publisher.close
  environment.close
end
