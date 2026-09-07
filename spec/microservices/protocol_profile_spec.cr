require "../spec_helper"
require "../../src/opal/microservices"

private alias MS = LF::Microservices

describe MS::TopologyConfig do
  it "is interoperable with tori-py by default" do
    topology = MS::TopologyConfig.new
    service = MS::ServiceIdentity.new("shop", "catalog", 1)
    event = MS::EventIdentity.new(service, "stock-changed", 2)

    topology.rpc_exchange.should eq("tori_py.rpc")
    topology.rpc_queue(service).should eq("tori_py.rpc.shop.catalog.v1")
    topology.rpc_binding(service).should eq("shop.catalog.v1.*")
    topology.event_exchange(service).should eq("tori_py.events.shop.catalog.v1")
    topology.event_queue_base(event).should eq(
      "tori_py.event.shop.catalog.v1.stock-changed.v2"
    )
    topology.reply_route("0123456789abcdef0123456789abcdef").value.should eq(
      "reply.0123456789abcdef0123456789abcdef"
    )
    topology.dead_letter_exchange.should eq("tori_py.dead-letter")
  end

  it "makes every physical topology namespace configurable" do
    topology = MS::TopologyConfig.new(
      rpc_exchange: "opal.rpc",
      rpc_queue_prefix: "opal.rpc.queue",
      event_exchange_prefix: "opal.events",
      event_queue_prefix: "opal.event.queue",
      reply_queue_prefix: "opal.reply",
      dead_letter_exchange: "opal.dead-letter",
      retry_exchange_prefix: "opal.retry",
    )
    service = MS::ServiceIdentity.new("shop", "catalog", 1)

    topology.rpc_exchange.should eq("opal.rpc")
    topology.rpc_queue(service).should eq("opal.rpc.queue.shop.catalog.v1")
    topology.event_exchange(service).should eq("opal.events.shop.catalog.v1")
    topology.reply_route("0123456789abcdef0123456789abcdef").value.should eq(
      "opal.reply.0123456789abcdef0123456789abcdef"
    )
    topology.dead_letter_exchange.should eq("opal.dead-letter")
    topology.retry_exchange_prefix.should eq("opal.retry")
  end

  it "loads topology names from application configuration" do
    path = "/tmp/opal-microservices-profile-#{Process.pid}.yml"
    File.write(path, <<-YAML)
      microservices:
        topology:
          rpc_exchange: company.rpc
          reply_queue_prefix: company.reply
      YAML

    topology = MS::TopologyConfig.from_config(LF::ConfigService.new(path))
    topology.rpc_exchange.should eq("company.rpc")
    topology.reply_queue_prefix.should eq("company.reply")
    topology.event_exchange_prefix.should eq("tori_py.events")
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "rejects unsafe and oversized physical names early" do
    expect_raises(MS::TopologyError, "lowercase ASCII") do
      MS::TopologyConfig.new(rpc_exchange: "Company RPC")
    end
    expect_raises(MS::TopologyError, "127-byte") do
      MS::TopologyConfig.new(rpc_exchange: "a" * 128)
    end
    expect_raises(MS::TopologyError, "127-byte") do
      MS::TopologyConfig.new(retry_exchange_prefix: "a" * 128)
    end
    expect_raises(MS::TopologyError, "reply token") do
      MS::TopologyConfig.new.reply_route("not-a-token")
    end
  end
end

describe MS::ProtocolProfile do
  it "groups the wire version, media types, limits, and topology" do
    profile = MS::ProtocolProfile.new

    profile.version.should eq(1)
    profile.rpc_content_type.should contain("version=1")
    profile.event_content_type.should contain("version=1")
    profile.topology.rpc_exchange.should eq("tori_py.rpc")
  end
end
