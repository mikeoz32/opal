require "../spec_helper"
require "../../src/opal/microservices"

private alias MS = LF::Microservices

private class MessageTestContainer < LF::DI::Container
  def enter_scope(scope : String) : LF::DI::Container
    MessageTestContainer.new(self, scope)
  end
end

private class MessageAllowGuard < MS::Guard
  def initialize(@calls : Array(String))
  end

  def can_activate(context : MS::ExecutionContext) : Bool
    @calls << "guard:#{context.action}"
    true
  end
end

private class MessageRejectGuard < MS::Guard
  def can_activate(context : MS::ExecutionContext) : Bool
    false
  end
end

private class MessageWrappingInterceptor < MS::Interceptor
  def initialize(@calls : Array(String))
  end

  def intercept(context : MS::ExecutionContext, call_next : Proc(MS::ExecutionResult)) : MS::ExecutionResult
    @calls << "before"
    result = call_next.call
    @calls << "after"
    result
  end
end

private class MessagePayloadPipe < MS::Pipe
  def transform(
    value : MS::PipeValue,
    metadata : MS::ArgumentMetadata,
    context : MS::ExecutionContext,
  ) : MS::PipeValue
    JSON::Any.new("#{value.as_s}:#{metadata.name}:#{context.action}")
  end
end

private class MessageHandledError < Exception
end

private class MessageErrorFilter < MS::ExceptionFilter
  handles MessageHandledError

  def catch_typed(
    exception : MessageHandledError,
    context : MS::ExecutionContext,
  ) : MS::ExecutionResult
    JSON::Any.new("handled:#{context.action}")
  end
end

private def message_execution_context : MS::ExecutionContext
  service = MS::ServiceIdentity.new("shop", "catalog", 1)
  target = MS::RPCTarget.new(service, "find", 1)
  delivery = MS::EncodedDelivery.new(
    UUID.random,
    target.routing_key,
    Bytes.empty,
    Time.utc,
  )
  MS::ExecutionContext.new(
    delivery,
    MessageTestContainer.new.enter_scope("message"),
    "CatalogMessages",
    "find",
    rpc_target: target,
  )
end

describe MS::ExecutionContext do
  it "uses a real message scope and exactly one message identity" do
    context = message_execution_context

    context.dependency_scope.scope.should eq("message")
    context.rpc?.should be_true
    context.event?.should be_false
    expect_raises(MS::MessageConfigurationError, "exactly one") do
      MS::ExecutionContext.new(
        context.delivery,
        context.dependency_scope,
        "Controller",
        "action",
      )
    end
  ensure
    context.try(&.dependency_scope.exit)
  end
end

describe MS::ExecutionPipeline do
  it "reuses the transport-neutral guard orchestration" do
    context = message_execution_context
    calls = [] of String

    MS::ExecutionPipeline.authorized?(context, [MessageAllowGuard.new(calls)] of MS::Guard)
      .should be_true
    MS::ExecutionPipeline.authorized?(context, [MessageRejectGuard.new] of MS::Guard)
      .should be_false
    calls.should eq(["guard:find"])
  ensure
    context.try(&.dependency_scope.exit)
  end

  it "applies message pipes with message metadata" do
    context = message_execution_context
    metadata = MS::ArgumentMetadata.new("request", "FindRequest", MS::ArgumentSource::Payload)

    result = MS::ExecutionPipeline.apply_pipes(
      JSON::Any.new("value"),
      metadata,
      context,
      [MessagePayloadPipe.new] of MS::Pipe,
    )
    result.as_s.should eq("value:request:find")
  ensure
    context.try(&.dependency_scope.exit)
  end

  it "nests interceptors and lets typed filters replace exceptions" do
    context = message_execution_context
    calls = [] of String

    result = MS::ExecutionPipeline.intercept(
      context,
      [MessageWrappingInterceptor.new(calls)] of MS::Interceptor,
    ) do
      calls << "action"
      JSON::Any.new("ok")
    end
    result.as_s.should eq("ok")
    calls.should eq(["before", "action", "after"])

    filtered = MS::ExecutionPipeline.catch(
      MessageHandledError.new,
      context,
      [MessageErrorFilter.new] of MS::Filter,
    )
    filtered.not_nil!.as_s.should eq("handled:find")
  ensure
    context.try(&.dependency_scope.exit)
  end
end
