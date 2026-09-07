require "../spec_helper"
require "../../src/opal/microservices"

private alias MS = LF::Microservices

private struct FindProductMessage
  include JSON::Serializable

  getter sku : String

  def initialize(@sku : String)
  end
end

private struct FindProductResult
  include JSON::Serializable

  getter available : Bool

  def initialize(@available : Bool)
  end
end

private struct StockChangedMessage
  include JSON::Serializable

  getter sku : String

  def initialize(@sku : String)
  end
end

private class HandlerPlanGuard < MS::Guard
  def can_activate(context : MS::ExecutionContext) : Bool
    true
  end
end

private class HandlerPlanPipe < MS::Pipe
  def transform(
    value : MS::PipeValue,
    metadata : MS::ArgumentMetadata,
    context : MS::ExecutionContext,
  ) : MS::PipeValue
    value
  end
end

private class HandlerPlanInterceptor < MS::Interceptor
  def intercept(context : MS::ExecutionContext, call_next : Proc(MS::ExecutionResult)) : MS::ExecutionResult
    call_next.call
  end
end

@[MS::UseGuards(HandlerPlanGuard)]
private class CatalogMessageController
  include MS::MessageController

  @[MS::RPC(method: "find", schema_version: 1)]
  @[MS::UseInterceptors(HandlerPlanInterceptor)]
  def find(@[MS::UsePipes(HandlerPlanPipe)] request : FindProductMessage) : FindProductResult
    FindProductResult.new(true)
  end

  @[MS::Event(
    namespace: "warehouse",
    service: "inventory",
    contract_version: 2,
    event: "stock-changed",
    schema_version: 3,
    subscription: "catalog-projector",
    mode: "service_pool"
  )]
  def stock_changed(event : StockChangedMessage) : Nil
  end
end

describe MS::HandlerRegistry do
  it "compiles explicit controllers into sealed typed handler metadata" do
    service = MS::ServiceIdentity.new("shop", "catalog", 1)
    registry = MS.compile_handlers(service, CatalogMessageController)

    registry.sealed?.should be_true
    registry.rpc_handlers.size.should eq(1)
    rpc = registry.rpc("shop.catalog.v1.find").not_nil!
    rpc.request_type.should eq("FindProductMessage")
    rpc.response_type.should eq("FindProductResult")
    rpc.policies.guards.should eq(["HandlerPlanGuard"])
    rpc.policies.pipes.should eq(["HandlerPlanPipe"])
    rpc.policies.interceptors.should eq(["HandlerPlanInterceptor"])

    registry.event_handlers.size.should eq(1)
    event = registry.event_handlers.first
    event.identity.source.should eq(MS::ServiceIdentity.new("warehouse", "inventory", 2))
    event.identity.routing_key.should eq("stock-changed.v3")
    event.subscription.should eq("catalog-projector")
    event.mode.service_pool?.should be_true
  end

  it "cannot be mutated after compilation" do
    service = MS::ServiceIdentity.new("shop", "catalog", 1)
    registry = MS.compile_handlers(service, CatalogMessageController)

    expect_raises(MS::HandlerCompilationError, "sealed") do
      registry.add(MS::RPCHandlerPlan.new(
        MS::RPCTarget.new(service, "other", 1),
        "Controller",
        "other",
        "Request",
        "Response",
      ))
    end
  end
end
