# RabbitMQ Streams projections

Opal's Crabbit integration is the first CQRS building block: publish typed
integration events and consume them with durable, replayable projection
handlers. It supports ordinary RabbitMQ streams and partitioned super streams.
It does not introduce a command bus, query bus, event store, or
`EventSourcedEntity`; those can be layered on this foundation later.

Use AMQP 0-9-1 queues from the [microservices guide](getting-started.md) for RPC,
work queues, delayed retries, and dead-letter routing. Use RabbitMQ Streams when
the consumer needs a durable log, broker checkpoints, replay, or independently
evolving read models.

## Run the complete example

Enable RabbitMQ's stream listener with the repository's Compose environment:

```bash
docker compose -f integration/rabbitmq/compose.yml up -d --wait
```

Then run the compiling example:

```bash
OPAL_CONFIG=examples/crabbit_streams_projection.yml \
  crystal run examples/crabbit_streams_projection.cr
```

The process creates the development topology, publishes one event, projects it,
prints its physical stream and offset, and shuts down cleanly. Production
deployments should provision topology outside the application and leave
`create_topology` disabled.

## Declare a typed stream event

Every event is an application-owned JSON DTO with a stable protocol identity:

```crystal
--8<-- "examples/crabbit_streams_projection.cr:event"
```

The compiler rejects a missing or duplicated `StreamEventContract`, non-literal
identity fields, or a DTO that does not include `JSON::Serializable`. The
identity becomes the existing Opal `EventEnvelope`, so stream events retain the
same message, source, event, schema, correlation, causation, headers, timestamp,
and payload fields as other Opal/Tori protocol v1 events.

Changing a payload incompatibly requires a new `schema_version`. A projection
may handle several event types, but each topology/subscription/event identity
combination may have only one handler.

## Declare topology

An ordinary stream preserves one total broker order:

```crystal
--8<-- "examples/crabbit_streams_projection.cr:topology"
```

A super stream preserves order only inside each partition:

```crystal
class OrdersStream
  include LF::Microservices::StreamTopology
  super_stream "orders-events", 6
end
```

Publishers must supply a stable routing key for a super stream, normally the
aggregate identifier. Events with the same key are routed to the same physical
partition:

```crystal
publisher.publish(
  OrdersStream,
  OrderCreated.new(order.id, order.total_cents),
  routing_key: order.id,
  correlation_id: context.correlation_id,
  causation_id: context.delivery.message_id,
).await
```

The returned `StreamPublishReceipt` represents broker confirmation, not
projection success. `await` raises `StreamPublishError` after rejection,
connection failure, or confirmation timeout.

## Write a projection handler

Handlers are typed DI services rather than untyped callbacks:

```crystal
--8<-- "examples/crabbit_streams_projection.cr:handler"
```

The compiler requires exactly one method with this shape:

```crystal
def handle(event : SomeStreamEvent, context : LF::Microservices::StreamContext) : Nil
```

Each attempt enters a fresh `message` DI scope. Constructor dependencies and
policies are resolved from that scope and disposed before the delivery is
checkpointed. `StreamContext#stream_metadata` exposes:

| Field | Meaning |
| --- | --- |
| `topology` | Declared logical stream or super-stream name |
| `stream` | Physical stream/partition receiving the event |
| `subscription` | Stable projection subscription name |
| `offset` | Absolute RabbitMQ stream offset |
| `timestamp` | Broker chunk timestamp |
| `super_stream` | Logical super stream, or `nil` for an ordinary stream |

The ordinary message context fields also expose the event identity, message ID,
correlation/causation IDs, application headers, and current DI scope.

### Reuse guards, pipes, interceptors, and filters

The same transport-neutral policies used by Opal message controllers work on a
stream handler:

```crystal
@[LF::Microservices::UseGuards(TenantGuard)]
@[LF::Microservices::UseInterceptors(ProjectionMetrics)]
@[LF::Microservices::UseFilters(KnownProjectionErrorFilter)]
@[LF::Microservices::StreamHandler(
  topology: OrdersStream,
  subscription: "orders_read_model",
)]
class OrdersReadModelProjection
  include LF::Microservices::StreamProjection

  def handle(
    @[LF::Microservices::UsePipes(NormalizeOrder)] event : OrderCreated,
    context : LF::Microservices::StreamContext,
  ) : Nil
    # Update the read model in one local transaction.
  end
end
```

Guards, pipes, interceptors, and filters may annotate the class or `handle`;
payload pipes may also annotate the event argument, matching ordinary message
controllers. Action filters run before class filters.

A filter that handles an exception makes that attempt successful, so the offset
may advance. Let the exception escape when the delivery must retry or stop the
partition.

## Autoconfigure the worker

Declare closed topology and handler type lists on the application:

```crystal
--8<-- "examples/crabbit_streams_projection.cr:application"
```

The extension connects once, validates or creates topology, registers a
singleton `StreamPublisher` and `StreamHandlerRuntime`, starts consumers, and
participates in application quiesce and shutdown. `bootstrap_stream_worker`
returns the normal `ApplicationRuntime`; `run_stream_worker` blocks until the
process receives a termination signal.

```yaml
microservices:
  streams:
    url: rabbitmq-stream://opal:opal@rabbitmq:5552/opal
    producer_name: orders-service
    load_balancer: false
    create_topology: false
    initial_offset: first
    initial_credit: 10
    buffer_size: 1024
    concurrency: 1
    topology_refresh_ms: 30000
    single_active_consumer: true
    retry:
      max_attempts: 5
      initial_delay_ms: 250
      max_delay_ms: 10000
```

| Key | Default | Purpose |
| --- | --- | --- |
| `url` | local guest stream URL | Crabbit connection URI |
| `producer_name` | `opal` | Stable producer prefix used for broker deduplication |
| `load_balancer` | `false` | Connect producer/consumer sockets through configured entrypoints instead of broker-advertised addresses |
| `create_topology` | `false` | Create missing development/test topology |
| `initial_offset` | `first` | Start point without a checkpoint: `first`, `next`, `last`, or `timestamp` |
| `initial_timestamp_ms` | none | Positive Unix milliseconds required with `timestamp` |
| `initial_credit` | `10` | Broker chunks allowed in flight per partition |
| `buffer_size` | `1024` | Buffered logical deliveries per partition |
| `concurrency` | `1` | Handler fibers per physical partition |
| `topology_refresh_ms` | `30000` | Super-stream partition reconciliation interval |
| `single_active_consumer` | `true` | Keep one active replica per named partition subscription |
| `retry.*` | shown above | Bounded in-process handler retry policy |

Keep `producer_name` stable across restarts of one logical producer and distinct
between independent producers. The low-level `StreamPublisher` accepts custom
`Crabbit::ProducerOptions`, but they must retain a stable name and event filter
extractor.

Set `load_balancer: true` when `url` points to a Docker port mapping or TCP load
balancer and RabbitMQ metadata advertises an internal broker hostname.

## Checkpoints and delivery guarantees

The subscription annotation is also the RabbitMQ consumer reference. Opal reads
its broker-stored offset at startup and resumes at the following delivery. No
PostgreSQL checkpoint table is involved.

Processing is **at least once**:

1. decode and validate the Opal event envelope;
2. enter a new message scope and run policies plus the typed handler;
3. dispose the scope;
4. mark the delivery processed;
5. let Crabbit store the latest contiguous processed offset.

With concurrent handlers, Crabbit never checkpoints past an earlier unfinished
delivery, but later handlers may already have produced side effects. Projection
writes must therefore be idempotent, normally by recording the event message ID
or last applied version in the same local transaction as the read-model update.
There is no exactly-once or distributed-transaction claim.

Unknown event identities are ignored and checkpointed so multiple typed event
handlers can share one subscription. A known event with an unsupported schema
version is a poison delivery and stops its partition.

## Poison events and recovery

After `retry.max_attempts`, Opal:

- leaves the failed offset unprocessed;
- closes only that physical stream/partition consumer;
- marks `StreamHandlerRuntime#status` as `Degraded` and `ready?` as false;
- records a `StreamPartitionFailure` with topology, subscription, stream,
  offset, exception, attempts, and timestamp;
- keeps healthy partitions running.

Inspect `runtime.failures`, fix or deliberately filter the bad event, then
restart only that partition:

```crystal
runtime.resume(
  failure.topology,
  failure.subscription,
  failure.stream,
)
```

The consumer starts from the broker checkpoint, so the poison event is
delivered again. `resume` returns `false` when the failure no longer exists.
Automatic skipping and implicit dead-lettering are intentionally absent because
either would silently create a hole in a replayable projection.

## Topology ownership and readiness

With `create_topology: false`, missing topology fails startup. With it enabled,
concurrent replicas tolerate the normal declare race and read the winner's
topology back. Super streams verify their required deterministic partitions and
accept later additive partitions using the same name prefix; incompatible or
removed required partitions degrade or fail the runtime.

Readiness is true only while the runtime is fully `Running`. A poison partition
or topology refresh failure changes it to `Degraded`; quiescing and closed
runtimes are also not ready. During shutdown, intake stops before Opal waits for
accepted handlers and pending publisher confirmations against the shared
application deadline.
