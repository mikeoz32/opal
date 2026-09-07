require "../spec_helper"
require "../../src/opal/microservices"

private alias MS = LF::Microservices

private class ExecutorTrace
  class_property calls = [] of String

  def self.reset : Nil
    self.calls = [] of String
  end
end

private class ExecutorDependency
  include LF::DI::Disposable

  class_property destroyed = 0
  class_property fail_destroy = false

  def touch : Nil
    ExecutorTrace.calls << "controller"
  end

  def destroy : Nil
    self.class.destroyed += 1
    raise "scope cleanup failed" if self.class.fail_destroy
  end
end

private struct ExecutorRequest
  include JSON::Serializable

  getter sku : String

  def initialize(@sku : String)
  end
end

private struct ExecutorResponse
  include JSON::Serializable

  getter available : Bool

  def initialize(@available : Bool)
  end
end

private class ExecutorGuard < MS::Guard
  def can_activate(context : MS::ExecutionContext) : Bool
    ExecutorTrace.calls << "guard"
    context.headers.has_key?("tenant")
  end
end

private class ExecutorPipe < MS::Pipe
  def transform(
    value : MS::PipeValue,
    metadata : MS::ArgumentMetadata,
    context : MS::ExecutionContext,
  ) : MS::PipeValue
    ExecutorTrace.calls << "pipe:#{metadata.name}"
    value
  end
end

private class ExecutorInterceptor < MS::Interceptor
  def intercept(context : MS::ExecutionContext, call_next : Proc(MS::ExecutionResult)) : MS::ExecutionResult
    ExecutorTrace.calls << "before"
    result = call_next.call
    ExecutorTrace.calls << "after"
    result
  end
end

private class ExecutorHandledFailure < Exception
end

private class ExecutorUnhandledFailure < Exception
end

private class ExecutorFilter < MS::ExceptionFilter
  handles ExecutorHandledFailure

  def catch_typed(
    exception : ExecutorHandledFailure,
    context : MS::ExecutionContext,
  ) : MS::ExecutionResult
    ExecutorTrace.calls << "filter"
    JSON.parse(ExecutorResponse.new(false).to_json)
  end
end

@[MS::UseGuards(ExecutorGuard)]
@[MS::UseFilters(ExecutorFilter)]
private class ExecutableCatalogMessages
  include MS::MessageController

  def initialize(@dependency : ExecutorDependency)
  end

  @[MS::RPC(method: "find", schema_version: 1)]
  @[MS::UseInterceptors(ExecutorInterceptor)]
  def find(@[MS::UsePipes(ExecutorPipe)] request : ExecutorRequest) : ExecutorResponse
    @dependency.touch
    raise ExecutorHandledFailure.new if request.sku == "handled"
    raise ExecutorUnhandledFailure.new if request.sku == "both"
    ExecutorResponse.new(request.sku == "opal-1")
  end

  @[MS::Event(
    namespace: "warehouse",
    service: "inventory",
    contract_version: 1,
    event: "stock-changed",
    schema_version: 1,
    subscription: "catalog-projector",
    mode: "service_pool"
  )]
  def stock_changed(@[MS::UsePipes(ExecutorPipe)] event : ExecutorRequest) : Nil
    @dependency.touch
  end
end

private class CountingMessageScopes
  include LF::DI::ScopeProvider

  getter entered = 0

  def initialize(@root : LF::DI::DefaultContainer)
  end

  def enter_scope(scope : String) : LF::DI::Container
    @entered += 1
    @root.enter_scope(scope)
  end
end

private def executor_service : MS::ServiceIdentity
  MS::ServiceIdentity.new("shop", "catalog", 1)
end

private def register_executor_policies(root : LF::DI::DefaultContainer) : Nil
  root.add_bean(name: "executor_dependency", scope: "message", type: ExecutorDependency) do
    ExecutorDependency.new
  end
  root.add_bean(name: "executor_guard", scope: "message", type: ExecutorGuard) do
    ExecutorGuard.new
  end
  root.add_bean(name: "executor_pipe", scope: "message", type: ExecutorPipe) do
    ExecutorPipe.new
  end
  root.add_bean(name: "executor_interceptor", scope: "message", type: ExecutorInterceptor) do
    ExecutorInterceptor.new
  end
  root.add_bean(name: "executor_filter", scope: "message", type: ExecutorFilter) do
    ExecutorFilter.new
  end
end

private def build_executor(root : LF::DI::DefaultContainer, scopes : LF::DI::ScopeProvider = root)
  register_executor_policies(root)
  registry = MS.compile_executable_handlers(
    executor_service,
    root,
    ExecutableCatalogMessages
  )
  {MS::HandlerExecutor.new(registry, scopes), registry}
end

private def executor_request(
  sku : String = "opal-1",
  created_at : Time = Time.utc(2026, 1, 1, 12),
  headers : Hash(String, JSON::Any) = {"tenant" => JSON::Any.new("acme")},
) : MS::RPCRequestEnvelope
  MS::RPCRequestEnvelope.new(
    message_id: UUID.new("11111111-1111-4111-8111-111111111111"),
    service: executor_service,
    method: "find",
    schema_version: 1,
    created_at: created_at,
    deadline_at: created_at + 5.seconds,
    correlation_id: UUID.new("22222222-2222-4222-8222-222222222222"),
    reply_to: MS::ReplyRoute.new("reply.0123456789abcdef0123456789abcdef"),
    headers: headers,
    payload: JSON.parse(ExecutorRequest.new(sku).to_json),
  )
end

private def executor_delivery(request : MS::RPCRequestEnvelope) : MS::EncodedDelivery
  MS::EncodedDelivery.new(
    request.message_id,
    MS::RPCTarget.new(request.service, request.method, request.schema_version).routing_key,
    MS::JSONCodec.new.encode_request(request),
    request.created_at,
    headers: {"broker-attempt" => JSON::Any.new(1_i64)},
    correlation_id: request.correlation_id,
    reply_to: request.reply_to,
    expires_at: request.deadline_at,
  )
end

describe MS::HandlerExecutor do
  before_each do
    ExecutorTrace.reset
    ExecutorDependency.destroyed = 0
    ExecutorDependency.fail_destroy = false
  end

  it "executes typed RPC handlers and policies in one disposable message scope" do
    root = LF::DI::DefaultContainer.new
    executor, _ = build_executor(root)
    request = executor_request

    result = executor.invoke_rpc(
      executor_delivery(request),
      request,
      now: request.created_at + 1.second,
    )

    result["available"].as_bool.should be_true
    ExecutorTrace.calls.should eq(["guard", "pipe:request", "before", "controller", "after"])
    ExecutorDependency.destroyed.should eq(1)
  ensure
    root.try(&.shutdown)
  end

  it "keeps broker headers separate from application envelope headers" do
    root = LF::DI::DefaultContainer.new
    executor, _ = build_executor(root)
    request = executor_request(headers: {} of String => JSON::Any)

    expect_raises(MS::MessageAuthorizationError) do
      executor.invoke_rpc(
        executor_delivery(request),
        request,
        now: request.created_at + 1.second,
      )
    end
    ExecutorTrace.calls.should eq(["guard"])
  ensure
    root.try(&.shutdown)
  end

  it "allows message filters to replace a handler failure" do
    root = LF::DI::DefaultContainer.new
    executor, _ = build_executor(root)
    request = executor_request("handled")

    result = executor.invoke_rpc(
      executor_delivery(request),
      request,
      now: request.created_at + 1.second,
    )

    result["available"].as_bool.should be_false
    ExecutorTrace.calls.should eq(["guard", "pipe:request", "before", "controller", "filter"])
    ExecutorDependency.destroyed.should eq(1)
  ensure
    root.try(&.shutdown)
  end

  it "executes event handlers through their explicit subscription" do
    root = LF::DI::DefaultContainer.new
    executor, registry = build_executor(root)
    plan = registry.event_handlers.first
    occurred_at = Time.utc(2026, 1, 1, 12)
    envelope = MS::EventEnvelope.new(
      UUID.random,
      plan.identity.source,
      plan.identity.event,
      plan.identity.schema_version,
      occurred_at,
      headers: {"tenant" => JSON::Any.new("acme")},
      payload: JSON.parse(ExecutorRequest.new("opal-1").to_json),
    )
    subscription = MS::EventSubscription.new(
      plan.identity,
      plan.mode,
      plan.subscription,
      destination: executor_service,
      reliable: plan.reliable,
    )
    delivery = MS::EncodedDelivery.new(
      envelope.message_id,
      plan.identity.routing_key,
      MS::JSONCodec.new.encode_event(envelope),
      occurred_at,
      headers: {"broker-attempt" => JSON::Any.new(1_i64)},
      subscription: subscription,
    )

    executor.invoke_event(delivery, envelope, now: occurred_at + 1.second).raw.should be_nil
    ExecutorTrace.calls.should eq(["guard", "pipe:event", "controller"])
    ExecutorDependency.destroyed.should eq(1)
  ensure
    root.try(&.shutdown)
  end

  it "rejects expired work before entering a message scope" do
    root = LF::DI::DefaultContainer.new
    scopes = CountingMessageScopes.new(root)
    executor, _ = build_executor(root, scopes)
    request = executor_request

    expect_raises(MS::WireDeadlineError) do
      executor.invoke_rpc(
        executor_delivery(request),
        request,
        now: request.deadline_at,
      )
    end
    scopes.entered.should eq(0)
    ExecutorDependency.destroyed.should eq(0)
  ensure
    root.try(&.shutdown)
  end

  it "rejects malformed wire data before entering a message scope" do
    root = LF::DI::DefaultContainer.new
    scopes = CountingMessageScopes.new(root)
    executor, _ = build_executor(root, scopes)
    delivery = MS::EncodedDelivery.new(
      UUID.random,
      "shop.catalog.v1.find",
      %({"kind":"rpc_request"}).to_slice,
      Time.utc,
    )

    expect_raises(MS::WireDecodingError) do
      executor.dispatch_rpc(delivery)
    end
    scopes.entered.should eq(0)
  ensure
    root.try(&.shutdown)
  end

  it "accepts absent legacy content type and rejects an unsupported profile before scope" do
    root = LF::DI::DefaultContainer.new
    scopes = CountingMessageScopes.new(root)
    executor, _ = build_executor(root, scopes)
    request = executor_request
    legacy = executor_delivery(request)

    executor.dispatch_rpc(legacy, now: request.created_at + 1.second)
    scopes.entered.should eq(1)

    unsupported = MS::EncodedDelivery.new(
      request.message_id,
      legacy.routing_key,
      legacy.body,
      legacy.received_at,
      headers: legacy.headers,
      correlation_id: legacy.correlation_id,
      reply_to: legacy.reply_to,
      expires_at: legacy.expires_at,
      content_type: "application/json;version=99",
    )
    expect_raises(MS::WireDecodingError, "unsupported RPC content_type") do
      executor.dispatch_rpc(unsupported, now: request.created_at + 1.second)
    end
    scopes.entered.should eq(1)
  ensure
    root.try(&.shutdown)
  end

  it "preserves both handler and scope cleanup failures" do
    root = LF::DI::DefaultContainer.new
    executor, _ = build_executor(root)
    request = executor_request("both")
    ExecutorDependency.fail_destroy = true

    error = expect_raises(MS::MessageScopeError) do
      executor.invoke_rpc(
        executor_delivery(request),
        request,
        now: request.created_at + 1.second,
      )
    end
    error.body_error.should be_a(ExecutorUnhandledFailure)
    error.scope_error.should be_a(LF::DI::BeanDestructionError)
  ensure
    ExecutorDependency.fail_destroy = false
    root.try(&.shutdown)
  end
end
