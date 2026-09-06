require "../src/opal/microservices"

alias MS = LF::Microservices

struct FindProduct
  include JSON::Serializable

  getter sku : String

  def initialize(@sku : String)
  end
end

struct ProductAvailability
  include JSON::Serializable

  getter available : Bool

  def initialize(@available : Bool)
  end
end

struct StockChanged
  include JSON::Serializable

  getter sku : String
  getter stock : Int64

  def initialize(@sku : String, @stock : Int64)
  end
end

class TenantGuard < MS::Guard
  def can_activate(context : MS::ExecutionContext) : Bool
    context.headers.has_key?("tenant")
  end
end

@[MS::UseGuards(TenantGuard)]
class CatalogMessages
  include MS::MessageController

  @[MS::RPC(method: "find", schema_version: 1)]
  def find(request : FindProduct) : ProductAvailability
    ProductAvailability.new(available: request.sku == "opal-1")
  end

  @[MS::Event(
    namespace: "warehouse",
    service: "inventory",
    contract_version: 2,
    event: "stock-changed",
    schema_version: 3,
    subscription: "catalog-projector",
    mode: "service_pool"
  )]
  def stock_changed(event : StockChanged) : Nil
  end
end

topology = MS::TopologyConfig.new(
  rpc_exchange: "company.rpc",
  rpc_queue_prefix: "company.rpc.queue",
  event_exchange_prefix: "company.events",
  event_queue_prefix: "company.event.queue",
  reply_queue_prefix: "company.reply",
  dead_letter_exchange: "company.dead-letter",
  retry_exchange_prefix: "company.retry",
)
profile = MS::ProtocolProfile.new(topology: topology)
codec = MS::JSONCodec.new(profile)
service = MS::ServiceIdentity.new("shop", "catalog", 1)
root = LF::DI::DefaultContainer.new
root.add_bean(name: "tenant_guard", scope: "message", type: TenantGuard) do
  TenantGuard.new
end
application = LF::ApplicationRuntime.new(root)
broker = MS::InMemoryBroker.new
server = MS::InMemoryServerTransport.new(broker, service)
runtime = application.install(
  MS::ServerRuntime.new(service, server, codec) do |context|
    MS.compile_executable_handlers(service, context, CatalogMessages)
  end
)
client = MS::InMemoryClientTransport.new(broker, topology)
client.start

created_at = MS.utc_now
request = MS::RPCRequestEnvelope.new(
  message_id: UUID.random,
  service: service,
  method: "find",
  schema_version: 1,
  created_at: created_at,
  deadline_at: created_at + 5.seconds,
  correlation_id: UUID.random,
  reply_to: client.reply_to,
  headers: {"tenant" => JSON::Any.new("acme")},
  payload: JSON.parse(FindProduct.new("opal-1").to_json),
)

wire = codec.encode_request(request)
decoded = codec.decode_request(wire)
target = MS::RPCTarget.new(service, request.method, request.schema_version)
publication = MS::Publication.new(
  request.message_id,
  target.routing_key,
  wire,
  mandatory: true,
  correlation_id: request.correlation_id,
  reply_to: request.reply_to,
  expires_at: request.deadline_at,
  content_type: codec.profile.rpc_content_type,
)
client.publish_rpc(target, publication)
server.dispatch_one
response = codec.decode_response(client.next_reply.as(MS::EncodedDelivery).body)

puts "RPC exchange: #{topology.rpc_exchange}"
puts "RPC queue: #{topology.rpc_queue(service)}"
puts "Compiled RPC handlers: #{runtime.registry.rpc_handlers.size}"
puts "Decoded payload: #{decoded.payload.to_json}"
puts "Handler result: #{response.result.not_nil!.to_json}"

client.close
application.shutdown
