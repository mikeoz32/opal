require "../src/opal/autoconfig/microservices/crabbit_streams"

alias MS = LF::Microservices

PROJECTION_COMPLETED = Channel(String).new(1)

# --8<-- [start:event]
@[MS::StreamEventContract(
  namespace: "shop",
  service: "orders",
  contract_version: 1,
  event: "order_created",
  schema_version: 1,
)]
struct OrderCreated
  include JSON::Serializable
  include MS::StreamEvent

  getter order_id : String
  getter total_cents : Int64

  def initialize(@order_id : String, @total_cents : Int64)
  end
end

# --8<-- [end:event]

# --8<-- [start:topology]
class OrdersStream
  include MS::StreamTopology
  stream "orders-events"
end

# --8<-- [end:topology]

# --8<-- [start:handler]
@[LF::DI::Service]
@[MS::StreamHandler(
  topology: OrdersStream,
  subscription: "orders_read_model",
)]
class OrdersReadModelProjection
  include MS::StreamProjection

  def handle(event : OrderCreated, context : MS::StreamContext) : Nil
    metadata = context.stream_metadata.not_nil!
    puts "projected #{event.order_id} from #{metadata.stream}@#{metadata.offset}"
    PROJECTION_COMPLETED.send(event.order_id)
  end
end

# --8<-- [end:handler]

# --8<-- [start:application]
@[LF::Application]
@[LF::AutoConfig::CrabbitStreams(
  topologies: [OrdersStream],
  handlers: [OrdersReadModelProjection],
)]
class OrdersProjectionApplication
end

# --8<-- [end:application]

# --8<-- [start:run]
runtime = OrdersProjectionApplication.bootstrap_stream_worker
begin
  publisher = runtime.resolve(MS::StreamPublisher)
  order_id = UUID.random.to_s
  publisher.publish(
    OrdersStream,
    OrderCreated.new(order_id, 4_250_i64),
  ).await

  select
  when projected = PROJECTION_COMPLETED.receive
    puts "projection completed for #{projected}"
  when timeout(10.seconds)
    raise "projection timed out"
  end
ensure
  runtime.shutdown unless runtime.closed?
end
# --8<-- [end:run]
