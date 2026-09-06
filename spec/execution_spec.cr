require "./spec_helper"
require "../src/opal"

record ExecutionSpecContext, trace : Array(String)
record ExecutionSpecArgument, name : String

class ExecutionSpecGuard < LF::Execution::Guard(ExecutionSpecContext)
  def initialize(@allowed : Bool)
  end

  def can_activate(context : ExecutionSpecContext) : Bool
    context.trace << "guard"
    @allowed
  end
end

class ExecutionSpecPipe < LF::Execution::Pipe(String, ExecutionSpecArgument, ExecutionSpecContext)
  def transform(
    value : String,
    metadata : ExecutionSpecArgument,
    context : ExecutionSpecContext,
  ) : String
    context.trace << "pipe:#{metadata.name}"
    value.upcase
  end
end

class ExecutionSpecInterceptor < LF::Execution::Interceptor(ExecutionSpecContext, String)
  def initialize(@name : String)
  end

  def intercept(context : ExecutionSpecContext, call_next : Proc(String)) : String
    context.trace << "before:#{@name}"
    result = call_next.call
    context.trace << "after:#{@name}"
    result
  end
end

class ExecutionSpecFilter < LF::Execution::Filter(ExecutionSpecContext, String)
  def catch(exception : Exception, context : ExecutionSpecContext) : String?
    context.trace << "filter:#{exception.message}"
    "recovered"
  end
end

describe LF::Execution::Pipeline do
  it "runs transport-neutral guards and pipes" do
    trace = [] of String
    context = ExecutionSpecContext.new(trace)
    guards = [ExecutionSpecGuard.new(true).as(LF::Execution::Guard(ExecutionSpecContext))]
    pipes = [ExecutionSpecPipe.new.as(LF::Execution::Pipe(String, ExecutionSpecArgument, ExecutionSpecContext))]

    LF::Execution::Pipeline.authorized?(context, guards).should be_true
    LF::Execution::Pipeline
      .apply_pipes("opal", ExecutionSpecArgument.new("payload"), context, pipes)
      .should eq("OPAL")
    trace.should eq(["guard", "pipe:payload"])
  end

  it "enters interceptors in declaration order and unwinds in reverse" do
    trace = [] of String
    context = ExecutionSpecContext.new(trace)
    interceptors = [
      ExecutionSpecInterceptor.new("outer"),
      ExecutionSpecInterceptor.new("inner"),
    ].map(&.as(LF::Execution::Interceptor(ExecutionSpecContext, String)))

    result = LF::Execution::Pipeline.intercept(context, interceptors) do
      trace << "action"
      "done"
    end

    result.should eq("done")
    trace.should eq([
      "before:outer",
      "before:inner",
      "action",
      "after:inner",
      "after:outer",
    ])
  end

  it "returns the first filter result" do
    trace = [] of String
    context = ExecutionSpecContext.new(trace)
    filters = [ExecutionSpecFilter.new.as(LF::Execution::Filter(ExecutionSpecContext, String))]

    LF::Execution::Pipeline
      .catch(Exception.new("failed"), context, filters)
      .should eq("recovered")
    trace.should eq(["filter:failed"])
  end
end
