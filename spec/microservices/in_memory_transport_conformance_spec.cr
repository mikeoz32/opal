require "../spec_helper"
require "../../src/opal/microservices"
require "../support/microservices/transport_conformance"

private class InMemoryTransportConformanceHarness
  getter service = LF::Microservices::ServiceIdentity.new("shop", "catalog", 1)
  getter event = LF::Microservices::EventIdentity.new(
    LF::Microservices::ServiceIdentity.new("warehouse", "inventory", 1),
    "stock-changed",
    1,
  )
  getter target : LF::Microservices::RPCTarget

  @broker : LF::Microservices::InMemoryBroker
  @servers = [] of LF::Microservices::InMemoryServerTransport
  @clients = [] of LF::Microservices::InMemoryClientTransport

  def initialize
    @target = LF::Microservices::RPCTarget.new(service, "find", 1)
    @broker = LF::Microservices::InMemoryBroker.new(
      -> { Time.utc(2026, 1, 1, 12) },
    )
  end

  def start_server(
    handler : LF::Microservices::DeliveryHandler,
    subscriptions : Array(LF::Microservices::EventSubscription) = [] of LF::Microservices::EventSubscription,
    max_queue_size : Int32 = 1_024,
  ) : LF::Microservices::InMemoryServerTransport
    server = LF::Microservices::InMemoryServerTransport.new(
      @broker,
      service,
      max_queue_size: max_queue_size,
    )
    server.prepare([target.method], subscriptions)
    server.start(handler)
    @servers << server
    server
  end

  def start_client(
    receive_replies : Bool = true,
    max_pending : Int32 = 1_024,
  ) : LF::Microservices::InMemoryClientTransport
    client = LF::Microservices::InMemoryClientTransport.new(
      @broker,
      max_pending: max_pending,
    )
    client.start(receive_replies: receive_replies)
    @clients << client
    client
  end

  def rpc_publication(
    client : LF::Microservices::InMemoryClientTransport,
    number : Int32 = 1,
  ) : LF::Microservices::Publication
    correlation_id = UUID.new("22222222-2222-4222-8222-#{number.to_s.rjust(12, '0')}")
    LF::Microservices::Publication.new(
      UUID.random,
      target.routing_key,
      Bytes[number],
      mandatory: true,
      correlation_id: correlation_id,
      reply_to: client.reply_to,
      expires_at: Time.utc(2026, 1, 1, 12, 0, 5),
    )
  end

  def event_publication(number : Int32 = 1) : LF::Microservices::Publication
    LF::Microservices::Publication.new(
      UUID.random,
      event.routing_key,
      Bytes[number],
      mandatory: true,
    )
  end

  def dispatch_one(
    server : LF::Microservices::InMemoryServerTransport,
  ) : LF::Microservices::EncodedDelivery?
    server.dispatch_one
  end

  def pending_count(server : LF::Microservices::InMemoryServerTransport) : Int32
    server.pending_count
  end

  def inflight_count(server : LF::Microservices::InMemoryServerTransport) : Int32
    server.inflight_count
  end

  def close : Nil
    @clients.each(&.close)
    @servers.each(&.close)
  end
end

MicroservicesTransportConformance.define(
  "in-memory transport conformance",
  InMemoryTransportConformanceHarness,
)
