require "../spec_helper"
require "../../src/opal/microservices/crabbit_streams"

private alias MS = LF::Microservices

private class StreamPolicyTrace
  class_property calls = [] of String
end

@[MS::StreamEventContract(
  namespace: "shop",
  service: "orders",
  contract_version: 1,
  event: "created",
  schema_version: 1,
)]
private struct StreamPolicyEvent
  include JSON::Serializable
  include MS::StreamEvent

  getter order_id : String

  def initialize(@order_id : String)
  end
end

private class StreamPolicyTopology
  include MS::StreamTopology
  stream "policy-events"
end

private class StreamPolicyGuard < MS::Guard
  def can_activate(context : MS::ExecutionContext) : Bool
    StreamPolicyTrace.calls << "guard"
    context.stream?
  end
end

private class StreamPolicyPipe < MS::Pipe
  def transform(
    value : MS::PipeValue,
    metadata : MS::ArgumentMetadata,
    context : MS::ExecutionContext,
  ) : MS::PipeValue
    StreamPolicyTrace.calls << "pipe:#{metadata.name}"
    value
  end
end

private class StreamPolicyInterceptor < MS::Interceptor
  def intercept(context : MS::ExecutionContext, call_next : Proc(MS::ExecutionResult)) : MS::ExecutionResult
    StreamPolicyTrace.calls << "before"
    result = call_next.call
    StreamPolicyTrace.calls << "after"
    result
  end
end

private class StreamPolicyFailure < Exception
end

private class StreamPolicyFilter < MS::ExceptionFilter
  handles StreamPolicyFailure

  def catch_typed(
    exception : StreamPolicyFailure,
    context : MS::ExecutionContext,
  ) : MS::ExecutionResult
    StreamPolicyTrace.calls << "filter"
    JSON::Any.new(nil)
  end
end

@[MS::UseGuards(StreamPolicyGuard)]
@[MS::UseInterceptors(StreamPolicyInterceptor)]
@[MS::UseFilters(StreamPolicyFilter)]
@[MS::StreamHandler(topology: StreamPolicyTopology, subscription: "policy_projection")]
private class StreamPolicyProjection
  include MS::StreamProjection

  class_property fail = false

  def handle(
    @[MS::UsePipes(StreamPolicyPipe)] event : StreamPolicyEvent,
    context : MS::StreamContext,
  ) : Nil
    StreamPolicyTrace.calls << "handler:#{event.order_id}:#{context.stream_metadata.not_nil!.offset}"
    raise StreamPolicyFailure.new if self.class.fail
  end
end

private def stream_policy_context(scope : LF::DI::Container) : MS::ExecutionContext
  identity = StreamPolicyEvent.stream_event_identity
  delivery = MS::EncodedDelivery.new(
    UUID.random,
    identity.routing_key,
    Bytes.empty,
    Time.utc,
  )
  MS::ExecutionContext.new(
    delivery,
    scope,
    StreamPolicyProjection.name,
    "handle",
    event_identity: identity,
    stream_metadata: MS::StreamDeliveryMetadata.new(
      "policy-events",
      "policy-events",
      "policy_projection",
      7_u64,
      Time.utc,
    ),
  )
end

private def register_stream_policy_beans(root : LF::DI::DefaultContainer) : Nil
  root.add_bean(name: "stream_policy_guard", scope: "message", type: StreamPolicyGuard) { StreamPolicyGuard.new }
  root.add_bean(name: "stream_policy_pipe", scope: "message", type: StreamPolicyPipe) { StreamPolicyPipe.new }
  root.add_bean(name: "stream_policy_interceptor", scope: "message", type: StreamPolicyInterceptor) { StreamPolicyInterceptor.new }
  root.add_bean(name: "stream_policy_filter", scope: "message", type: StreamPolicyFilter) { StreamPolicyFilter.new }
  root.add_bean(name: "stream_policy_projection", scope: "message", type: StreamPolicyProjection) { StreamPolicyProjection.new }
end

describe "Crabbit Streams handler policies" do
  before_each do
    StreamPolicyTrace.calls = [] of String
    StreamPolicyProjection.fail = false
  end

  it "reuses guards, pipes, interceptors, and stream delivery context" do
    root = LF::DI::DefaultContainer.new
    register_stream_policy_beans(root)
    scope = root.enter_scope("message")
    registry = MS.compile_stream_handlers(StreamPolicyProjection)
    handler = registry.subscriptions.first.handler(StreamPolicyEvent.stream_event_identity).not_nil!

    handler.invoke(
      scope,
      stream_policy_context(scope),
      JSON.parse(StreamPolicyEvent.new("order-1").to_json),
    )

    StreamPolicyTrace.calls.should eq([
      "guard",
      "pipe:event",
      "before",
      "handler:order-1:7",
      "after",
    ])
  ensure
    scope.try(&.exit)
    root.try(&.shutdown)
  end

  it "lets a typed message filter settle a projection failure" do
    root = LF::DI::DefaultContainer.new
    register_stream_policy_beans(root)
    scope = root.enter_scope("message")
    registry = MS.compile_stream_handlers(StreamPolicyProjection)
    handler = registry.subscriptions.first.handler(StreamPolicyEvent.stream_event_identity).not_nil!
    StreamPolicyProjection.fail = true

    handler.invoke(
      scope,
      stream_policy_context(scope),
      JSON.parse(StreamPolicyEvent.new("order-2").to_json),
    )

    StreamPolicyTrace.calls.should eq([
      "guard",
      "pipe:event",
      "before",
      "handler:order-2:7",
      "filter",
    ])
  ensure
    scope.try(&.exit)
    root.try(&.shutdown)
  end
end
