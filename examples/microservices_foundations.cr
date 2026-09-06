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

class CatalogClient
  include MS::TypedServiceClient

  service "shop", "catalog", 1
  rpc find, FindProduct, ProductAvailability, "find", 1
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
rpc = MS::RPCClient.new(client, codec)
catalog = CatalogClient.new(rpc)
spawn do
  loop do
    if server.pending_count > 0
      server.dispatch_one
      break
    end
    Fiber.yield
  end
end
result = catalog.find(
  FindProduct.new("opal-1"),
  timeout: 5.seconds,
  headers: {"tenant" => JSON::Any.new("acme")},
)

puts "RPC exchange: #{topology.rpc_exchange}"
puts "RPC queue: #{topology.rpc_queue(service)}"
puts "Compiled RPC handlers: #{runtime.registry.rpc_handlers.size}"
puts "Typed handler result: #{result.to_json}"

application.shutdown
rpc.close
