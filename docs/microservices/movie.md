# Movie actors and event sourcing

[`opal-movie`](https://github.com/mikeoz32/opal-movie) is the optional adapter
for applications that need Movie actors, clustering, sharding, or
event-sourced entities. It is kept outside Opal so ordinary HTTP, LiveView, and
Data applications do not acquire an actor runtime or Movie's persistence
drivers.

## Responsibilities

| Concern | Owner |
| --- | --- |
| HTTP, WebSockets, LiveView, policies, DI, lifecycle | Opal |
| Application-specific command/query gateways | Your application |
| Actors, ask/tell, clustering, sharding, singletons | Movie |
| Event-sourced entities, journal, snapshots, recovery | Movie |
| Local journal projections | `Movie::Persistence::ProjectionRunner` |
| Cross-service event publication | Movie outbox + `opal-movie` relay + Crabbit |
| External read models | Opal StreamHandler + Opal Data |

The adapter deliberately does not add another command bus or query bus. A
gateway is a typed application boundary around Movie actor references; Movie
continues to own delivery and routing semantics.

## Install

```yaml
dependencies:
  opal:
    github: mikeoz32/opal
    version: ~> 0.1.0
  opal_movie:
    github: mikeoz32/opal-movie
    version: ~> 0.1.0
```

```crystal
require "opal_movie"
```

## Configure a typed actor system

Define one concrete guardian and let Opal construct it through normal DI:

```crystal
record CreateOrder, order_id : String

@[LF::DI::Service]
class OrdersGuardian < Movie::AbstractBehavior(CreateOrder)
  def receive(command : CreateOrder, context : Movie::ActorContext(CreateOrder))
    # Route to a child actor or a sharded entity here.
    Movie::Behaviors(CreateOrder).same
  end
end

@[LF::Application]
@[LF::AutoConfig::Movie(message: CreateOrder, guardian: OrdersGuardian)]
class OrdersApplication
end
```

`OrdersApplication.bootstrap` registers all of these singleton beans:

- `Movie::ActorSystem(CreateOrder)` as `movie_actor_system`;
- `LF::MovieIntegration::RuntimeBase` as `movie_runtime`;
- `LF::MovieIntegration::ReadinessProbe` as `movie_readiness`.

A controller should depend on an application-specific gateway rather than the
actor system directly:

```crystal
@[LF::DI::Service]
class OrdersGateway
  def initialize(@movie_actor_system : Movie::ActorSystem(CreateOrder))
  end

  def create(order_id : String) : Nil
    @movie_actor_system << CreateOrder.new(order_id)
  end
end
```

## One application configuration

Opal and Movie read the same `config/application.yml`, including a path
selected with `OPAL_CONFIG`. Movie ignores Opal-owned keys and Opal ignores
Movie-owned keys.

```yaml
name: orders

http:
  host: 0.0.0.0
  port: 8080

opal:
  movie:
    await_cluster_up: true
    startup_timeout_ms: 10000
    shutdown_timeout_ms: 10000

remoting:
  enabled: true
  host: 0.0.0.0
  port: 2552

cluster:
  enabled: true
  name: orders
  seed-nodes:
    - movie://orders@orders-0:2552
```

When clustering is enabled, bootstrap waits for the local member to become
`Up` by default. The readiness probe remains false while the system is joining
or shutting down.

## Graceful shutdown

Autoconfiguration priorities establish this reverse shutdown order:

1. HTTP stops accepting requests and drains active work.
2. The outbox relay finishes its current claimed batch.
3. Crabbit Streams drains pending broker confirmations.
4. Movie requests cluster leave, waits for local removal, and stops actors.
5. Opal Data and the root DI container close last.

Timeouts surface as retryable `ApplicationExtension::StopIncomplete` errors,
so Opal does not destroy dependencies that actors or a relay may still use.

## Transactional outbox

Movie already persists outbox rows atomically with `EventEffect` and
`DurableEffect`. Enable the adapter relay together with Opal's Crabbit Streams
autoconfiguration:

```crystal
@[LF::Application]
@[LF::AutoConfig::Movie(message: CreateOrder, guardian: OrdersGuardian)]
@[LF::AutoConfig::CrabbitStreams(
  topologies: [OrdersIntegrationStream],
)]
class OrdersApplication
end
```

```yaml
opal:
  movie:
    outbox:
      enabled: true
      batch_size: 100
      poll_interval_ms: 250
      lease_ms: 30000
      confirmation_timeout_ms: 30000

microservices:
  streams:
    url: rabbitmq-stream://guest:guest@localhost:5552/%2f
    producer_name: orders
    load_balancer: false
```

Attach a typed Opal integration event to the effect returned by an existing
Movie `EventSourcedBehavior`:

```crystal
persist(domain_event, command.operation_id)
  .then_publish(
    LF::MovieIntegration.stream_event(
      OrdersIntegrationStream,
      Integration::OrderPlaced.new(command.order_id),
      routing_key: command.order_id,
      correlation_id: command.correlation_id,
    )
  )
```

The helper stores a stable Opal event envelope in Movie's outbox. The relay
uses Movie's existing lease/claim dispatcher, accepts only topologies declared
on `@[LF::AutoConfig::CrabbitStreams]`, waits for the Crabbit broker
confirmation, and acknowledges the row afterward.

This is at-least-once delivery. Use the envelope `message_id` as the
idempotency key in downstream projections.

## Local and external projections

Use `Movie::Persistence::ProjectionRunner` when a projection belongs to the
same service and can read its journal. Use `LF::Microservices::StreamHandler`
when another service owns the read model or the event must cross a deployment
boundary. Do not publish Movie remoting frames as integration events: Movie
remoting is appropriate inside the actor cluster but is not a durable
cross-service protocol.
