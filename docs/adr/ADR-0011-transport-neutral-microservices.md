# ADR-0011: Transport-Neutral Microservices

- Status: Accepted
- Date: 2026-09-06
- Deciders: Opal maintainers
- Extends: ADR-0002, ADR-0003, ADR-0005, ADR-0008
- Reference: [Tori Py microservices architecture](https://github.com/mikeoz32/tori-py/blob/main/TORI_PY_MICROSERVICES_ARCHITECTURE.md)

## Context

Opal already provides compile-time application bootstrap, dependency injection,
scoped resource ownership, HTTP controllers, request policies, PostgreSQL,
transactions, migrations, WebSockets, and LiveView. Applications still need a
consistent way to split deployable services without leaking persistence models,
local commands, or transport implementation details across service boundaries.

The Tori Py microservices package demonstrates the desired operational model:
one logical service identity per application, explicit typed RPC contracts,
transport-neutral handler execution, RabbitMQ adapters, finite RPC deadlines,
at-least-once delivery, application-owned outbox/inbox patterns, and graceful
quiescence before dependency shutdown.

Opal should adopt these semantics in a Crystal-native form. It must not copy
Python runtime reflection, dynamic Protocol proxies, or Tori's module graph.
Crystal macros and explicit application composition should move validation to
compile time wherever possible.

## Decision

### Package boundary

The microservices API is opt-in. `require "opal"` does not load a broker or
register message infrastructure automatically.

- `opal` owns generic application lifecycle, DI, execution policies, and Data.
- `opal/microservices` owns transport-neutral RPC and event semantics, handler
  compilation, codecs, clients, and an in-memory transport.
- a RabbitMQ adapter is distributed separately so the base Opal shard does not
  acquire an AMQP dependency.
- a future RabbitMQ Streams adapter may use Crabbit for event streams, but it is
  not a substitute for the AMQP 0-9-1 queues and exchanges required by RPC.

### Application and service identity

One compiled application may configure at most one local service identity:

```text
ServiceIdentity(namespace, name, contract_version)
```

An API gateway may configure only outbound clients and no local service root.
Multiple replicas of the same service use the same logical identity and compete
for deliveries. Running unrelated logical services inside one application is
not supported initially.

### Explicit contracts and discovery

Wire contracts are application-owned DTOs. They are not Opal Data entities,
internal CQRS commands, queries, or domain events.

Outbound service contracts declare the destination identity, RPC alias, request
type, response type, schema version, and default deadline. Crystal macros
generate typed client implementations and validate the declaration at compile
time. There is no dynamic method proxy.

Inbound RPC and event handlers live on explicit message controller types. The
compiler uses included controller types and annotations, following the existing
HTTP controller model. It does not scan files, enumerate packages, or populate a
mutable runtime registry.

Handler aliases must be unique within a service. Handler signatures, payload
types, result types, policy types, and constructor dependencies are validated
before transport intake starts.

### Delivery scope and execution pipeline

Every delivery enters a fresh `message` DI scope. Message-scoped dependencies
are destroyed before the transport settles the delivery. A controller is
resolved inside that scope and must not retain delivery context after return.

Guards, pipes, interceptors, and exception filters share transport-neutral
orchestration under `LF::Execution`. HTTP and messaging expose their own typed
contexts and values. Broker handlers never receive a fabricated HTTP request or
response.

The message execution order is:

1. validate transport metadata and envelope limits;
2. reject expired work before DI or database acquisition;
3. enter the message DI scope;
4. guards;
5. payload/header binding and pipes;
6. interceptors and controller invocation;
7. result validation and response encoding for RPC;
8. exception filters;
9. scope cleanup;
10. transport settlement.

### Lifecycle

Application shutdown is two phase:

1. `quiesce(ShutdownContext)` stops intake and drains already accepted work
   against one application-wide deadline;
2. `stop` closes transport resources;
3. root DI closes only after extensions have stopped.

`ApplicationExtension#quiesce` has a default no-op for compatibility. Extensions
that own concurrent work must implement it and make it safe to retry. A quiesce
failure preserves extensions and root DI so shutdown can be retried without
destroying dependencies still in use.

### Transport contract

The microservices runtime depends only on transport-neutral interfaces:

- server transport preparation, intake, deadline-bound drain, settlement, and
  lifecycle;
- client publication, reply delivery, reconnect generations, and explicit
  outcome-unknown correlations without automatic replay;
- publication receipts that distinguish accepted/routed from handler success;
- explicit event subscriptions;
- observable transport status.

A transport does not resolve DI, inspect annotations, invoke policies, or own
message scopes. `ServerRuntime` composes those framework concerns with the
transport and application lifecycle. The in-memory transport implements the
same contract and is the first conformance target, but it does not claim process
or broker durability.

The JSON envelope and logical routing contract are defined by
[Opal/Tori Messaging Protocol v1](../microservices/protocol-v1.md). Physical
exchange, queue, reply, retry, and dead-letter namespaces belong to a
`TopologyConfig`. Its defaults match Tori Py v1, while deployments may replace
every namespace without changing service identities or envelope bytes.

### RPC semantics

Every RPC has a finite deadline and bounded pending-request capacity. Correlation
IDs, causation IDs, safe headers, creation time, expiry, service identity, method,
and schema version are explicit envelope fields.

The client distinguishes:

- broker rejection or unroutable destination;
- public remote failure;
- deadline exceeded;
- transport failure before acceptance;
- outcome unknown after acceptance or connection loss.

Opal does not automatically retry accepted or outcome-unknown RPC calls. A
timeout or disconnected caller does not prove remote rollback.

### RabbitMQ AMQP topology

The initial RabbitMQ adapter targets AMQP 0-9-1 and uses publisher confirms,
mandatory routing, manual settlement, bounded prefetch, and separate publishing
and consuming resources where required for backpressure isolation.

- one durable RPC queue per logical service;
- one wildcard binding for all RPC methods of that service;
- replicas are equal competing consumers;
- one exclusive auto-delete reply queue per live client cluster generation;
- source-specific topic exchanges for events;
- bounded retry queues and dead-letter queues for durable subscriptions.

The reply must be confirmed and routed before the request is acknowledged.
Connection loss fails pending calls whose outcome cannot be proven and creates a
new reply route before accepting new calls. Pending calls are never replayed
implicitly.

None of the `tori_py.*` names are hard-coded into identity values or transport
interfaces. They are compatibility defaults supplied by the protocol profile.

### Event delivery modes

Subscriptions explicitly select one mode:

- service pool: one durable queue for a destination service and subscription;
- singleton: one durable queue shared by all consumers of the subscription;
- broadcast: one queue per live instance, ephemeral by default and optionally
  durable when a stable instance identity and retention bounds are provided.

All durable event delivery is at least once. Retry counts and storage are
bounded. Poison messages terminate in a dead-letter queue rather than an
unbounded requeue loop.

### Persistence reliability

Opal Data supplies reusable primitives for an application-owned outbox relay and
inbox deduplication, but does not publish ORM lifecycle events automatically.

The reliable producer path is:

```text
local transaction: domain changes + outbox row
outbox relay: publish with stable event id
broker: at-least-once delivery
consumer transaction: inbox/deduplication + effects
ACK after transaction commit
```

Every service owns its database, migrations, entities, repositories, and local
transaction boundaries. Shared database tables and cross-service entity loading
are outside the model.

### Security and observability

Transport headers and routing keys are untrusted input. Authentication context
propagation is explicit, minimal, validated, and independent of HTTP session
state. The adapter supports TLS and least-privilege broker credentials.

Every invocation exposes stable service, method/event, message, correlation,
causation, attempt, redelivery, and duration fields for logging and metrics.
Readiness requires prepared topology and active intake, not merely a live
process.

## Non-goals

- automatic service splitting or package scanning;
- sharing Opal Data entities or internal CQRS messages over the wire;
- exactly-once delivery or distributed transactions;
- automatic retry of RPC requests;
- automatic publication of domain or ORM events;
- remote cancellation or streaming RPC in the first version;
- service discovery, membership, or load inference from broker consumer counts;
- requiring RabbitMQ, HTTP, Data, or CQRS in the transport-neutral core.

## Consequences

- Applications gain one consistent controller/DI/policy model across HTTP and
  messaging while retaining transport-specific contexts.
- Compile-time contracts remove a class of runtime proxy and signature errors.
- Delivery guarantees are explicit and testable rather than hidden behind a
  convenient request API.
- The framework requires a new quiesce phase and a transport-neutral extraction
  of the current HTTP policy orchestration.
- RabbitMQ interoperability depends on an AMQP 0-9-1 client passing Opal's
  transport conformance and failure-recovery tests.
- Outbox/inbox helpers increase Data scope, but transaction ownership remains
  visible in application code.

## Delivery order

1. application quiesce lifecycle and shutdown deadline;
2. transport-neutral execution policy contracts with HTTP compatibility;
3. identities, envelopes, codecs, errors, handler plans, and in-memory transport;
4. typed RPC contract/client generation and message controllers;
5. RabbitMQ AMQP adapter and Docker conformance suite;
6. Opal Data outbox/inbox helpers;
7. gateway, catalog, orders, and notifications example with separate databases.
