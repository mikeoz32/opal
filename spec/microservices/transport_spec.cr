require "../spec_helper"
require "../../src/opal/microservices"

private alias MS = LF::Microservices

private def transport_service : MS::ServiceIdentity
  MS::ServiceIdentity.new("shop", "catalog", 1)
end

private def transport_event : MS::EventIdentity
  MS::EventIdentity.new(transport_service, "stock-changed", 1)
end

describe MS::EventSubscription do
  it "defaults durable modes to reliable" do
    pool = MS::EventSubscription.new(
      transport_event,
      MS::EventDispatchMode::ServicePool,
      "projector",
      destination: transport_service,
    )
    singleton = MS::EventSubscription.new(
      transport_event,
      MS::EventDispatchMode::Singleton,
      "reporter",
    )

    pool.reliable.should be_true
    singleton.reliable.should be_true
  end

  it "defaults broadcast to ephemeral and generates an instance identity" do
    subscription = MS::EventSubscription.new(
      transport_event,
      MS::EventDispatchMode::Broadcast,
      "live-stock",
      destination: transport_service,
    )

    subscription.reliable.should be_false
    subscription.instance_id.not_nil!.should match(/^instance-[0-9a-f]{32}$/)
  end

  it "requires stable instance identity for reliable broadcasts" do
    expect_raises(MS::TransportStateError, "instance_id") do
      MS::EventSubscription.new(
        transport_event,
        MS::EventDispatchMode::Broadcast,
        "audit",
        destination: transport_service,
        reliable: true,
      )
    end
  end
end

describe MS::Publication do
  it "copies bounded transport metadata and body" do
    body = Bytes[1, 2, 3]
    publication = MS::Publication.new(
      UUID.random,
      "shop.catalog.v1.find",
      body,
      content_type: MS::ProtocolProfile.new.rpc_content_type,
    )
    body[0] = 9
    exposed = publication.body
    exposed[1] = 9

    publication.body.should eq(Bytes[1, 2, 3])
    publication.mandatory.should be_false
  end

  it "rejects an oversized body before transport I/O" do
    expect_raises(MS::WireLimitError, "publication body") do
      MS::Publication.new(
        UUID.random,
        "shop.catalog.v1.find",
        Bytes.new(4),
        limits: MS::MessageLimits.new(max_envelope_bytes: 3),
      )
    end
  end
end

describe MS::EncodedDelivery do
  it "tracks attempt, redelivery, and expiration without broker types" do
    now = Time.utc(2026, 1, 1, 12)
    delivery = MS::EncodedDelivery.new(
      UUID.random,
      "shop.catalog.v1.find",
      Bytes[1],
      now,
      attempt: 2,
      redelivered: true,
      expires_at: now + 5.seconds,
    )

    delivery.attempt.should eq(2)
    delivery.redelivered.should be_true
    delivery.expired?(now + 4.seconds).should be_false
    delivery.expired?(now + 5.seconds).should be_true
  end

  it "rejects invalid delivery attempts" do
    expect_raises(MS::TransportStateError, "attempt") do
      MS::EncodedDelivery.new(
        UUID.random,
        "route",
        Bytes.empty,
        Time.utc,
        attempt: 0,
      )
    end
  end
end
