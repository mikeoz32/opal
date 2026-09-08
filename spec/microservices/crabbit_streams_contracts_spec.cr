require "../spec_helper"
require "../../src/opal/microservices/crabbit_streams"

alias MS = LF::Microservices

private class ContractOrdinaryStream
  include MS::StreamTopology
  stream "audit"
end

private class ContractSuperStream
  include MS::StreamTopology
  super_stream "orders", 3
end

describe MS::StreamTopologyDefinition do
  it "describes ordinary streams" do
    definition = ContractOrdinaryStream.stream_definition

    definition.kind.stream?.should be_true
    definition.partition_names.should eq(["audit"])
  end

  it "derives deterministic super stream partitions and binding keys" do
    definition = ContractSuperStream.stream_definition

    definition.super_stream?.should be_true
    definition.partition_names.should eq(["orders-0", "orders-1", "orders-2"])
    definition.binding_keys.should eq(["0", "1", "2"])
  end

  it "validates retry settings" do
    expect_raises(MS::StreamConfigurationError, /max_attempts/) do
      MS::StreamRetryPolicy.new(max_attempts: 0)
    end
  end
end

describe MS::StreamHandlerRegistry do
  it "rejects duplicate event routes in one subscription" do
    identity = MS::EventIdentity.new(MS::ServiceIdentity.new("shop", "orders", 1), "created", 1)
    topology = ContractOrdinaryStream.stream_definition
    invoker = MS::StreamHandlerInvoker.new { |_scope, _context, _payload| }
    handler = MS::CompiledStreamHandler.new(
      topology,
      ContractOrdinaryStream.name,
      "orders_projection",
      identity,
      "One",
      "handle",
      invoker,
    )
    duplicate = MS::CompiledStreamHandler.new(
      topology,
      ContractOrdinaryStream.name,
      "orders_projection",
      identity,
      "Two",
      "handle",
      invoker,
    )
    registry = MS::StreamHandlerRegistry.new
    registry.add(handler)

    expect_raises(MS::StreamConfigurationError, /duplicate stream handler/) do
      registry.add(duplicate)
    end
  end
end

describe MS::StreamPublisher do
  it "requires custom producer options to preserve deduplication and filtering" do
    environment = uninitialized Crabbit::Environment

    expect_raises(MS::StreamConfigurationError, /stable name/) do
      MS::StreamPublisher.new(
        environment,
        "orders",
        producer_options: Crabbit::ProducerOptions.new,
      )
    end

    expect_raises(MS::StreamConfigurationError, /filter_value_extractor/) do
      MS::StreamPublisher.new(
        environment,
        "orders",
        producer_options: Crabbit::ProducerOptions.new(name: "orders"),
      )
    end
  end
end
