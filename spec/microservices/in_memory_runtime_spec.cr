require "../spec_helper"
require "../../src/opal/microservices"

private alias MS = LF::Microservices

private struct RuntimeFindRequest
  include JSON::Serializable

  getter sku : String

  def initialize(@sku : String)
  end
end

private struct RuntimeFindResponse
  include JSON::Serializable

  getter available : Bool

  def initialize(@available : Bool)
  end
end

private class RuntimeRequestDependency
  include LF::DI::Disposable

  class_property destroyed = 0

  def destroy : Nil
    self.class.destroyed += 1
  end
end

private class RuntimeCatalogMessages
  include MS::MessageController

  def initialize(@dependency : RuntimeRequestDependency)
  end

  @[MS::RPC(method: "find", schema_version: 1)]
  def find(request : RuntimeFindRequest) : RuntimeFindResponse
    RuntimeFindResponse.new(request.sku == "opal-1")
  end
end

describe "in-memory microservices runtime" do
  it "runs typed RPC from publication through reply with scope cleanup" do
    now = Time.utc(2026, 1, 1, 12)
    service = MS::ServiceIdentity.new("shop", "catalog", 1)
    target = MS::RPCTarget.new(service, "find", 1)
    codec = MS::JSONCodec.new
    root = LF::DI::DefaultContainer.new
    root.add_bean(
      name: "runtime_request_dependency",
      scope: "message",
      type: RuntimeRequestDependency
    ) { RuntimeRequestDependency.new }
    registry = MS.compile_executable_handlers(service, root, RuntimeCatalogMessages)
    executor = MS::HandlerExecutor.new(registry, root)
    broker = MS::InMemoryBroker.new(-> { now })
    server = MS::InMemoryServerTransport.new(broker, service)
    server.prepare(["find"], [] of MS::EventSubscription)
    server.start(->(delivery : MS::EncodedDelivery) {
      result = executor.dispatch_rpc(delivery, codec, now: now)
      response = MS::RPCResponseEnvelope.success(
        UUID.new("44444444-4444-4444-8444-444444444444"),
        delivery.correlation_id.not_nil!,
        now,
        result,
      )
      server.publish_reply(MS::Publication.new(
        response.message_id,
        delivery.reply_to.not_nil!.value,
        codec.encode_response(response),
        mandatory: true,
        correlation_id: response.correlation_id,
        content_type: codec.profile.rpc_content_type,
      ))
      MS::SettlementRecommendation::Ack
    })
    client = MS::InMemoryClientTransport.new(broker)
    client.start
    created_at = now - 1.second
    request = MS::RPCRequestEnvelope.new(
      UUID.new("11111111-1111-4111-8111-111111111111"),
      service,
      "find",
      1,
      created_at,
      now + 4.seconds,
      UUID.new("22222222-2222-4222-8222-222222222222"),
      client.reply_to,
      payload: JSON.parse(RuntimeFindRequest.new("opal-1").to_json),
    )
    publication = MS::Publication.new(
      request.message_id,
      target.routing_key,
      codec.encode_request(request),
      mandatory: true,
      correlation_id: request.correlation_id,
      reply_to: request.reply_to,
      expires_at: request.deadline_at,
      content_type: codec.profile.rpc_content_type,
    )
    RuntimeRequestDependency.destroyed = 0

    client.publish_rpc(target, publication).routed.should be_true
    client.pending_count.should eq(1)
    server.dispatch_one
    decoded = codec.decode_response(client.next_reply.as(MS::EncodedDelivery).body)

    decoded.success?.should be_true
    decoded.result.not_nil!["available"].as_bool.should be_true
    RuntimeRequestDependency.destroyed.should eq(1)
    server.inflight_count.should eq(0)
  ensure
    client.try(&.close)
    server.try(&.close)
    root.try(&.shutdown)
  end
end
