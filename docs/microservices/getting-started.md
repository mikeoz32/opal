# Microservices foundations

The microservices package is opt-in and transport-neutral:

```crystal
require "opal/microservices"
```

Requiring `opal` alone does not load message contracts or a broker adapter.
The current API covers protocol configuration, identities, strict envelopes,
transport value contracts, message policies, compile-time handler plans,
message-scoped execution, typed RPC clients, and a deterministic in-memory
transport. The RabbitMQ adapter has its own opt-in entrypoint:

```crystal
require "opal/microservices/rabbitmq"
```

Neither `require "opal"` nor `require "opal/microservices"` loads the AMQP
client.
The complete compiling example is
[`examples/microservices_foundations.cr`](../../examples/microservices_foundations.cr).

## Configure the protocol

The default is immediately compatible with Tori Py v1:

```crystal
profile = LF::Microservices::ProtocolProfile.new
profile.topology.rpc_exchange # => "tori_py.rpc"
```

Physical names can be provided directly or loaded from `application.yml`:

```yaml
microservices:
  topology:
    rpc_exchange: company.rpc
    rpc_queue_prefix: company.rpc.queue
    event_exchange_prefix: company.events
    event_queue_prefix: company.event.queue
    reply_queue_prefix: company.reply
    dead_letter_exchange: company.dead-letter
    retry_exchange_prefix: company.retry
```

```crystal
config = LF::ConfigService.new
topology = LF::Microservices::TopologyConfig.from_config(config)
profile = LF::Microservices::ProtocolProfile.new(topology: topology)
codec = LF::Microservices::JSONCodec.new(profile)
```

The full wire contract and current Tori compatibility boundary are documented
in [Messaging Protocol v1](protocol-v1.md).

## Declare message DTOs

Wire DTOs are application-owned integration types, not Opal Data entities or
local CQRS messages:

```crystal
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
```

Protocol v1 JSON integers are signed 64-bit values. Use a string in the DTO
schema when a business identifier or number can exceed that range.

## Declare handlers

Controllers are explicit. Opal never scans directories or loads every class in
a namespace:

```crystal
class CatalogMessages
  include LF::Microservices::MessageController

  @[LF::Microservices::RPC(method: "find", schema_version: 1)]
  def find(request : FindProduct) : ProductAvailability
    ProductAvailability.new(available: true)
  end
end

service = LF::Microservices::ServiceIdentity.new("shop", "catalog", 1)
root = LF::DI::DefaultContainer.new
handlers = LF::Microservices.compile_executable_handlers(
  service,
  root,
  CatalogMessages
)
```

The compiler requires one explicit `JSON::Serializable` payload argument. RPC
handlers also require an explicit `JSON::Serializable` or `Nil` result type.
Event handlers require an explicit `Nil` result.

An event subscription describes its source contract as part of the annotation:

```crystal
struct StockChanged
  include JSON::Serializable

  getter sku : String
  getter stock : Int64

  def initialize(@sku : String, @stock : Int64)
  end
end

@[LF::Microservices::Event(
  namespace: "warehouse",
  service: "inventory",
  contract_version: 2,
  event: "stock-changed",
  schema_version: 3,
  subscription: "catalog-projector",
  mode: "service_pool"
)]
def stock_changed(event : StockChanged) : Nil
  # local transaction
end
```

Supported modes are `service_pool`, `singleton`, and `broadcast`. Durable modes
default to reliable delivery. Reliable broadcast will require a stable instance
identity when the transport subscription is created.

## Reuse guards, pipes, interceptors, and filters

Message policies use the same generic orchestration as HTTP but their own typed
context:

```crystal
class TenantGuard < LF::Microservices::Guard
  def can_activate(context : LF::Microservices::ExecutionContext) : Bool
    context.headers.has_key?("tenant")
  end
end

@[LF::Microservices::UseGuards(TenantGuard)]
class CatalogMessages
  include LF::Microservices::MessageController

  @[LF::Microservices::RPC(method: "find", schema_version: 1)]
  def find(request : FindProduct) : ProductAvailability
    ProductAvailability.new(available: true)
  end
end
```

`UseGuards`, `UsePipes`, `UseInterceptors`, and `UseFilters` may be placed on a
controller or action. `UsePipes` may also annotate the payload argument. Invalid
policy types, invalid handler signatures, and duplicate RPC aliases fail during
Crystal compilation.

Message code receives `LF::Microservices::ExecutionContext`, never a fabricated
HTTP request. The context exposes application headers from the decoded
envelope, correlation/causation IDs, the encoded broker delivery, exact
RPC/event identity, controller/action name, and message-scoped DI container.
Broker headers remain on `context.delivery.headers`; Opal never merges them with
the application headers.

Policies are ordinary DI providers. Register them with `scope: "message"` when
they own per-delivery state. `compile_executable_handlers` automatically
registers message controllers with the same scope and resolves their constructor
dependencies from it.

`HandlerExecutor#dispatch_rpc` and `#dispatch_event` decode and validate the
wire body before opening that scope. They also cross-check message ID, routing
key, correlation, reply route, subscription, expiry metadata, and a present
profile content type. An absent content type remains compatible with Tori v1.
The scope is closed after success, a filtered error, or an unhandled error. If
handler and scope cleanup both fail, `MessageScopeError` preserves both
exceptions.

## Declare a typed client

Application-owned service clients declare their fixed remote identity and
methods explicitly:

```crystal
class CatalogClient
  include LF::Microservices::TypedServiceClient

  service "shop", "catalog", 1
  rpc find, FindProduct, ProductAvailability, "find", 1
end
```

The DSL verifies at compile time that request and response DTOs include
`JSON::Serializable`; `Nil` is also a valid response. It generates a method
whose request and return types remain visible to Crystal:

```crystal
client_transport.start
rpc = LF::Microservices::RPCClient.new(client_transport, codec)
catalog = CatalogClient.new(rpc)

availability = catalog.find(
  FindProduct.new("opal-1"),
  timeout: 2.seconds,
  headers: {"tenant" => JSON::Any.new("acme")},
)
```

Every call has a positive finite timeout and unique correlation ID. Pending
calls are bounded by both `RPCClient` and the adapter. Failures are distinct:

- `RPCRejectedError`: rejected or unroutable before acceptance;
- `RPCTimeoutError`: the local deadline elapsed after acceptance;
- `RPCRemoteError`: a sanitized public error returned by the service;
- `RPCTransportError`: transport failure before acceptance;
- `RPCOutcomeUnknownError`: connection/reply-route loss after acceptance;
- `RPCProtocolError`: invalid envelope, metadata, content type, or response DTO.

Timeout and outcome-unknown do not prove that the remote handler rolled back.
The client never republishes an accepted request automatically. `reconnect`
creates a fresh reply generation and completes affected calls as
`RPCOutcomeUnknownError`.

## Use the in-memory transport

`InMemoryBroker`, `InMemoryServerTransport`, and `InMemoryClientTransport`
implement the same transport contracts intended for the RabbitMQ adapter. A
publication is accepted into a bounded queue before the handler executes:

```crystal
broker = LF::Microservices::InMemoryBroker.new
server = LF::Microservices::InMemoryServerTransport.new(broker, service)
application = LF::ApplicationRuntime.new(root)
runtime = application.install(
  LF::Microservices::ServerRuntime.new(service, server, codec) do |_context|
    handlers
  end
)

client = LF::Microservices::InMemoryClientTransport.new(broker, topology)
client.start
rpc = LF::Microservices::RPCClient.new(client, codec)
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
availability = catalog.find(
  FindProduct.new("opal-1"),
  headers: {"tenant" => JSON::Any.new("acme")},
)

application.shutdown
rpc.close
```

`ServerRuntime` derives RPC methods and event subscriptions from the sealed
registry. It sends a confirmed, mandatory response before acknowledging RPC,
maps unexpected exceptions to a fixed `internal_error` without exposing the
exception message, and uses `MessageRetryableError` as the default event retry
signal. A custom error mapper/classifier can be injected explicitly.

The implementation covers mandatory/unroutable publications, bounded pending
RPC and delivery queues, competing service consumers, service-pool and
broadcast events, reply correlation, retry/redelivery attempts, quiescing, and
new reply-route generations without automatic replay. It is deterministic test
infrastructure and provides no process or broker durability. Every future
adapter must pass the shared transport conformance harness before it is treated
as compatible.

## Use RabbitMQ

Add the broker connection and bounded-delivery policy to `application.yml`.
Keep production credentials in a secret-managed configuration file selected by
`OPAL_CONFIG`, rather than committing them:

```yaml
microservices:
  rabbitmq:
    url: amqp://guest:guest@127.0.0.1:5672
    prefetch: 32
    work_pool: 4
    max_attempts: 3
    max_queue_length: 10000
    retry_delay_ms: 1000
```

The topology and broker settings are independent. Construct both from the same
application configuration and pass the same profile to servers and clients:

```crystal
require "opal/microservices/rabbitmq"

config = LF::ConfigService.new
topology = LF::Microservices::TopologyConfig.from_config(config)
profile = LF::Microservices::ProtocolProfile.new(topology: topology)
codec = LF::Microservices::JSONCodec.new(profile)
settings = LF::Microservices::RabbitMQ::Settings.from_config(config)

server = LF::Microservices::RabbitMQ::ServerTransport.new(
  service,
  settings,
  profile,
)
application = LF::ApplicationRuntime.new(root)
application.install(
  LF::Microservices::ServerRuntime.new(service, server, codec) do |context|
    LF::Microservices.compile_executable_handlers(
      service,
      context,
      CatalogMessages,
    )
  end
)

client_transport = LF::Microservices::RabbitMQ::ClientTransport.new(
  settings,
  profile,
)
client_transport.start
rpc = LF::Microservices::RPCClient.new(client_transport, codec)
catalog = CatalogClient.new(rpc)
```

The adapter declares durable bounded RPC and reliable-event queues,
source-specific topic exchanges, per-method retry queues, and dead-letter
queues. Ephemeral broadcasts and client reply routes use exclusive auto-delete
queues. Publications use confirms; RPC requests and replies require mandatory
routing; consumers use bounded prefetch and manual settlement. Event
publications honor their explicit `mandatory` setting.

`Retry` republishes to a TTL retry queue with an incremented broker-only
`opal-attempt` header. The original delivery is acknowledged only after that
publication is confirmed and routed. Once `max_attempts` is reached, the
delivery is rejected without requeue and reaches its dead-letter queue. An
accepted RPC is never replayed automatically: reconnect creates a new reply
route and reports the prior pending correlation IDs as outcome-unknown.

Call `application.shutdown` before closing outbound RPC clients. Shutdown first
cancels consumer intake, waits for deliveries already handed to application
fibers, and then closes the broker connection. Messages still waiting in a
durable broker queue remain available to another replica.

Real-broker verification uses the pinned RabbitMQ 4 Compose environment and
commands in [`integration/rabbitmq/README.md`](../../integration/rabbitmq/README.md).
