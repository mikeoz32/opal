# Opal/Tori Messaging Protocol v1

This document defines the interoperable JSON and routing contract shared by
Opal microservices and `tori-py-microservices`. It is normative for protocol
version 1. Framework APIs, handler discovery, dependency injection, and broker
connection management are outside the wire protocol.

## Compatibility profile

`LF::Microservices::ProtocolProfile` selects protocol version, finite message
limits, media types, and physical topology. Version 1 is the only supported
wire version. It deliberately does not add a `protocol_version` JSON member:
Tori v1 rejects unknown envelope fields, so doing so would break existing
peers.

The media types are available to transport adapters for an explicit rollout:

```text
application/vnd.opal-tori.rpc+json;version=1
application/vnd.opal-tori.event+json;version=1
```

Current Tori v1 peers do not require or emit `content_type`. An adapter must
therefore treat an absent content type as version 1 during the compatibility
period. A present unsupported content type must be rejected before decoding.

## Logical identities

An alias matches `[a-z][a-z0-9_-]{0,62}`. Contract and schema versions are
positive signed 32-bit integers.

| Value | Form | Example |
| --- | --- | --- |
| Service label | `<namespace>.<service>.v<contract_version>` | `shop.catalog.v1` |
| RPC routing key | `<service-label>.<method>` | `shop.catalog.v1.find` |
| RPC service binding | `<service-label>.*` | `shop.catalog.v1.*` |
| Event routing key | `<event>.v<schema_version>` | `stock-changed.v2` |
| Reply route | `<configured-prefix>.<32-lowercase-hex>` | `reply.0123...cdef` |

Composed routing and queue names must fit RabbitMQ's 255-byte short-string
limit. Exchange names must fit 127 bytes.

## Configurable physical topology

Physical names are deployment configuration. The defaults preserve immediate
compatibility with Tori v1:

| Setting | Default |
| --- | --- |
| `rpc_exchange` | `tori_py.rpc` |
| `rpc_queue_prefix` | `tori_py.rpc` |
| `event_exchange_prefix` | `tori_py.events` |
| `event_queue_prefix` | `tori_py.event` |
| `reply_queue_prefix` | `reply` |
| `dead_letter_exchange` | `tori_py.dead-letter` |
| `retry_exchange_prefix` | `tori_py.retry` |

For example:

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

Every communicating runtime must use the same physical topology configuration.
Changing it does not change service labels, routing keys, or JSON envelopes.
The audited Tori v1 implementation currently configures only `rpc_exchange`;
the other custom namespaces require the corresponding Tori-side change. The
defaults work across Opal and Tori without that follow-up.

## JSON value rules

- Input and output are one UTF-8 JSON object with no trailing content.
- Duplicate object members and non-finite floats are rejected.
- Integers are signed 64-bit values. Applications must encode larger numbers as
  strings under their own DTO schema.
- Object keys are non-empty strings. Encoders sort nested object members by key.
- Timestamps are RFC 3339, explicitly UTC, with zero or six fractional digits.
- UUIDs use canonical lowercase hyphenated text.
- Unknown or missing envelope members are rejected.

Default limits are 1 MiB per envelope, 64 headers, 64 KiB for the encoded
headers object, nesting depth 64, and 10,000 members per individual collection.
The same configured limits apply while encoding and decoding.

## RPC request

An RPC request contains exactly these members, in this encoded order:

```json
{
  "message_id": "11111111-1111-4111-8111-111111111111",
  "kind": "rpc_request",
  "namespace": "shop",
  "service": "catalog",
  "contract_version": 1,
  "method": "find",
  "schema_version": 1,
  "created_at": "2026-01-01T12:00:00Z",
  "deadline_at": "2026-01-01T12:00:05Z",
  "correlation_id": "22222222-2222-4222-8222-222222222222",
  "causation_id": null,
  "reply_to": "reply.0123456789abcdef0123456789abcdef",
  "headers": {},
  "payload": null
}
```

`deadline_at` must be later than `created_at`. The server rejects a request
whose absolute deadline has elapsed before opening a message scope or acquiring
a database connection.

## RPC response

The base members are `message_id`, `kind`, `correlation_id`, and
`completed_at`. `kind` is `rpc_response`. Exactly one of `result` or `error`
must also be present. A successful JSON `null` result is distinct from a missing
result.

An error has exactly four members:

```json
{
  "code": "not_found",
  "message": "Product was not found.",
  "retryable": false,
  "details": {"sku": "opal-1"}
}
```

Only sanitized public errors cross the boundary. Stack traces, exception class
names, SQL, broker credentials, and private application state must not appear in
the error object.

## Event

An event contains exactly `message_id`, `kind`, `namespace`, `service`,
`contract_version`, `event`, `schema_version`, `occurred_at`, `correlation_id`,
`causation_id`, `headers`, and `payload`. `kind` is `event`. Correlation and
causation IDs may be JSON `null`.

## AMQP 0-9-1 mapping

The JSON body remains authoritative, and the adapter also maps trusted broker
properties:

| AMQP property | Protocol value |
| --- | --- |
| `message_id` | envelope `message_id` |
| `correlation_id` | envelope `correlation_id`, when present |
| `reply_to` | request `reply_to`, for RPC requests |
| `expiration` | absolute request expiry/deadline |
| `content_type` | profile media type when supported by both peers |

Requests and durable events are persistent; replies are transient. RPC and
reply publications use mandatory routing and publisher confirms. A server must
cross-check duplicated broker properties and the actual routing key against the
decoded envelope. It confirms and routes a reply before acknowledging its
request.

Broker headers are transport metadata. Application headers remain inside the
JSON envelope and must not be implicitly merged with broker headers.

The RabbitMQ adapter reserves the `opal-attempt` broker header. It is a positive
32-bit integer, starts at `1` when absent, and is incremented only when a retry
is republished. The adapter removes it before exposing delivery headers to
application code.

### RabbitMQ queue topology

With the default profile, a `shop.catalog.v1` service and its `find` method use:

| Resource | Name or binding |
| --- | --- |
| RPC exchange | `tori_py.rpc` |
| RPC queue | `tori_py.rpc.shop.catalog.v1` |
| RPC binding | `shop.catalog.v1.*` |
| Retry exchange | `tori_py.retry` |
| Method retry queue/key | `tori_py.rpc.shop.catalog.v1.retry.find` |
| Dead-letter exchange | `tori_py.dead-letter` |
| RPC dead-letter queue | `tori_py.rpc.shop.catalog.v1.dead` |

Primary and retry queues use `x-max-length` with `reject-publish`; retry queues
also use `x-message-ttl` and dead-letter back to the original exchange and
routing key. Primary queues dead-letter terminal rejections. Reliable event
subscriptions use the same bounded retry/dead-letter pattern. Queue declaration
arguments are part of the deployment contract: changing them for an existing
queue requires an explicit RabbitMQ migration rather than silently accepting a
precondition failure.

## Golden compatibility vectors

The canonical fixtures live in `spec/fixtures/microservices/wire-v1/`. They were
emitted by Tori Py's `MsgspecJsonMessageCodec` and are decoded and reproduced
byte-for-byte by Opal specs:

- `rpc-request.json`;
- `rpc-success.json`;
- `rpc-error.json`;
- `event.json`.

Any intentional change to these bytes requires a new protocol version and a
four-way compatibility suite: Tori client to Opal server, Opal client to Tori
server, and both same-runtime directions.
