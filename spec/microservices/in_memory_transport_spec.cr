require "../spec_helper"
require "../../src/opal/microservices"

private alias MS = LF::Microservices

private def memory_service : MS::ServiceIdentity
  MS::ServiceIdentity.new("shop", "catalog", 1)
end

private def memory_target : MS::RPCTarget
  MS::RPCTarget.new(memory_service, "find", 1)
end

private def rpc_publication(client : MS::InMemoryClientTransport, number : Int32 = 1) : MS::Publication
  correlation_id = UUID.new("22222222-2222-4222-8222-#{number.to_s.rjust(12, '0')}")
  MS::Publication.new(
    UUID.random,
    memory_target.routing_key,
    Bytes[number],
    mandatory: true,
    correlation_id: correlation_id,
    reply_to: client.reply_to,
    expires_at: Time.utc(2026, 1, 1, 12, 0, 5),
  )
end

private def start_memory_server(
  broker : MS::InMemoryBroker,
  handler : MS::DeliveryHandler,
  subscriptions : Array(MS::EventSubscription) = [] of MS::EventSubscription,
  max_queue_size : Int32 = 1_024,
) : MS::InMemoryServerTransport
  server = MS::InMemoryServerTransport.new(
    broker,
    memory_service,
    max_queue_size: max_queue_size,
  )
  server.prepare(["find"], subscriptions)
  server.start(handler)
  server
end

describe MS::InMemoryBroker do
  it "separates broker acceptance from RPC handler execution" do
    now = Time.utc(2026, 1, 1, 12)
    broker = MS::InMemoryBroker.new(-> { now })
    attempts = [] of Int32
    server = start_memory_server(
      broker,
      ->(delivery : MS::EncodedDelivery) {
        attempts << delivery.attempt
        MS::SettlementRecommendation::Ack
      },
    )
    client = MS::InMemoryClientTransport.new(broker)
    client.start
    publication = rpc_publication(client)

    receipt = client.publish_rpc(memory_target, publication)
    receipt.routed.should be_true
    receipt.accepted_at.should eq(now)
    server.pending_count.should eq(1)
    attempts.should be_empty

    server.dispatch_one.not_nil!.message_id.should eq(publication.message_id)
    attempts.should eq([1])
    server.pending_count.should eq(0)
    server.inflight_count.should eq(0)
  ensure
    client.try(&.close)
    server.try(&.close)
  end
end
