require "../spec_helper"
require "../../src/opal/microservices"

private alias MS = LF::Microservices

describe MS::ServiceIdentity do
  it "builds stable service, RPC, and event routing identities" do
    service = MS::ServiceIdentity.new("shop", "catalog", 2)

    service.label.should eq("shop.catalog.v2")
    MS::RPCTarget.new(service, "find-product", 3).routing_key
      .should eq("shop.catalog.v2.find-product")
    MS::EventIdentity.new(service, "stock-changed", 4).routing_key
      .should eq("stock-changed.v4")
  end

  it "rejects aliases and versions outside the protocol grammar" do
    expect_raises(MS::IdentityError, "namespace must match") do
      MS::ServiceIdentity.new("Shop", "catalog", 1)
    end
    expect_raises(MS::IdentityError, "contract_version must be a positive") do
      MS::ServiceIdentity.new("shop", "catalog", 0)
    end
  end
end

describe MS::MessageLimits do
  it "uses the Tori v1 finite defaults" do
    limits = MS::MessageLimits.new

    limits.max_envelope_bytes.should eq(1024 * 1024)
    limits.max_header_count.should eq(64)
    limits.max_header_bytes.should eq(64 * 1024)
    limits.max_nesting_depth.should eq(64)
    limits.max_collection_items.should eq(10_000)
  end

  it "rejects non-positive limits" do
    expect_raises(MS::WireLimitError, "max_header_count") do
      MS::MessageLimits.new(max_header_count: 0)
    end
  end
end

describe ".utc_now" do
  it "returns a protocol-v1-compatible UTC timestamp" do
    now = MS.utc_now

    now.offset.should eq(0)
    (now.nanosecond % 1_000).should eq(0)
  end
end
