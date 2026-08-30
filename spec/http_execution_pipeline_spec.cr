require "./spec_helper"
require "../src/opal"
require "http/client"

class PipelineSpecEvents
  @@values = [] of String

  def self.reset : Nil
    @@values.clear
  end

  def self.add(value : String) : Nil
    @@values << value
  end

  def self.values : Array(String)
    @@values.dup
  end
end

@[LF::DI::Service]
class PipelineSpecGlobalGuard < LF::HTTP::Guard
  def can_activate(context : LF::HTTP::ExecutionContext) : Bool
    PipelineSpecEvents.add("guard:global:#{context.controller}##{context.action}")
    true
  end
end

@[LF::DI::Service]
class PipelineSpecControllerGuard < LF::HTTP::Guard
  def can_activate(context : LF::HTTP::ExecutionContext) : Bool
    PipelineSpecEvents.add("guard:controller")
    true
  end
end

@[LF::DI::Service]
class PipelineSpecActionGuard < LF::HTTP::Guard
  def can_activate(context : LF::HTTP::ExecutionContext) : Bool
    PipelineSpecEvents.add("guard:action")
    true
  end
end

@[LF::DI::Service]
class PipelineSpecRejectGuard < LF::HTTP::Guard
  def can_activate(context : LF::HTTP::ExecutionContext) : Bool
    PipelineSpecEvents.add("guard:reject")
    false
  end
end

class PipelineSpecRequestGuard < LF::HTTP::Guard
  include LF::DI::Disposable

  @@created = 0
  @@destroyed = 0

  def self.reset : Nil
    @@created = 0
    @@destroyed = 0
  end

  def self.created : Int32
    @@created
  end

  def self.destroyed : Int32
    @@destroyed
  end

  def initialize
    @@created += 1
  end

  def can_activate(context : LF::HTTP::ExecutionContext) : Bool
    context.dependency_scope.scope == "request"
  end

  def destroy : Nil
    @@destroyed += 1
  end
end

@[LF::DI::Service]
class PipelineSpecGlobalPipe < LF::HTTP::StringPipe
  def transform_string(
    value : String,
    metadata : LF::HTTP::ArgumentMetadata,
    context : LF::HTTP::ExecutionContext,
  ) : String
    PipelineSpecEvents.add("pipe:global:#{metadata.source.to_s.downcase}:#{metadata.target_type}")
    value.strip
  end
end

@[LF::DI::Service]
class PipelineSpecControllerPipe < LF::HTTP::StringPipe
  def transform_string(
    value : String,
    metadata : LF::HTTP::ArgumentMetadata,
    context : LF::HTTP::ExecutionContext,
  ) : String
    PipelineSpecEvents.add("pipe:controller")
    "#{value}:controller"
  end
end

@[LF::DI::Service]
class PipelineSpecActionPipe < LF::HTTP::StringPipe
  def transform_string(
    value : String,
    metadata : LF::HTTP::ArgumentMetadata,
    context : LF::HTTP::ExecutionContext,
  ) : String
    PipelineSpecEvents.add("pipe:action")
    "#{value}:action"
  end
end

@[LF::DI::Service]
class PipelineSpecParameterPipe < LF::HTTP::StringPipe
  def transform_string(
    value : String,
    metadata : LF::HTTP::ArgumentMetadata,
    context : LF::HTTP::ExecutionContext,
  ) : String
    PipelineSpecEvents.add("pipe:parameter:#{metadata.name}")
    "#{value}:parameter"
  end
end

@[LF::DI::Service]
class PipelineSpecJSONPipe < LF::HTTP::JSONPipe
  def transform_json(
    value : JSON::Any,
    metadata : LF::HTTP::ArgumentMetadata,
    context : LF::HTTP::ExecutionContext,
  ) : JSON::Any
    PipelineSpecEvents.add("pipe:json:#{metadata.source.to_s.downcase}")
    body = value.as_h.dup
    body["name"] = JSON::Any.new(body["name"].as_s.upcase)
    JSON::Any.new(body)
  end
end

abstract class PipelineSpecInterceptor < LF::HTTP::Interceptor
  def initialize(@name : String)
  end

  def intercept(
    context : LF::HTTP::ExecutionContext,
    call_next : LF::HTTP::CallHandler,
  ) : LF::HTTP::Response
    PipelineSpecEvents.add("interceptor:#{@name}:before")
    response = call_next.call
    PipelineSpecEvents.add("interceptor:#{@name}:after")
    response
  end
end

@[LF::DI::Service]
class PipelineSpecGlobalInterceptor < PipelineSpecInterceptor
  def initialize
    super("global")
  end
end

@[LF::DI::Service]
class PipelineSpecControllerInterceptor < PipelineSpecInterceptor
  def initialize
    super("controller")
  end
end

@[LF::DI::Service]
class PipelineSpecActionInterceptor < PipelineSpecInterceptor
  def initialize
    super("action")
  end
end

@[LF::DI::Service]
class PipelineSpecShortCircuitInterceptor < LF::HTTP::Interceptor
  def intercept(
    context : LF::HTTP::ExecutionContext,
    call_next : LF::HTTP::CallHandler,
  ) : LF::HTTP::Response
    PipelineSpecEvents.add("interceptor:short-circuit")
    LF::HTTP::TextResponse.create("short-circuited")
  end
end

class PipelineSpecFailure < Exception
end

abstract class PipelineSpecFailureFilter < LF::HTTP::ExceptionFilter
  handles PipelineSpecFailure

  def initialize(@name : String)
  end

  def catch_typed(
    exception : PipelineSpecFailure,
    context : LF::HTTP::ExecutionContext,
  ) : LF::HTTP::Response
    PipelineSpecEvents.add("filter:#{@name}")
    context.response.status = HTTP::Status::UNPROCESSABLE_ENTITY
    LF::HTTP::TextResponse.create("#{@name}:#{exception.message}")
  end
end

@[LF::DI::Service]
class PipelineSpecGlobalFilter < PipelineSpecFailureFilter
  def initialize
    super("global")
  end
end

@[LF::DI::Service]
class PipelineSpecControllerFilter < PipelineSpecFailureFilter
  def initialize
    super("controller")
  end
end

@[LF::DI::Service]
class PipelineSpecActionFilter < PipelineSpecFailureFilter
  def initialize
    super("action")
  end
end

@[LF::DI::Service]
class PipelineSpecForbiddenFilter < LF::HTTP::ExceptionFilter
  handles LF::HTTP::Forbidden

  def catch_typed(
    exception : LF::HTTP::Forbidden,
    context : LF::HTTP::ExecutionContext,
  ) : LF::HTTP::Response
    PipelineSpecEvents.add("filter:forbidden")
    context.response.status = HTTP::Status::UNAUTHORIZED
    LF::HTTP::TextResponse.create("login required")
  end
end

class PipelineSpecPayload
  include JSON::Serializable

  getter name : String
end

@[LF::HTTP::UseGuards(PipelineSpecGlobalGuard)]
@[LF::HTTP::UsePipes(PipelineSpecGlobalPipe)]
@[LF::HTTP::UseInterceptors(PipelineSpecGlobalInterceptor)]
@[LF::HTTP::UseFilters(PipelineSpecGlobalFilter)]
class PipelineSpecGlobals
end

@[LF::HTTP::UseGuards(PipelineSpecControllerGuard)]
@[LF::HTTP::UsePipes(PipelineSpecControllerPipe)]
@[LF::HTTP::UseInterceptors(PipelineSpecControllerInterceptor)]
@[LF::HTTP::UseFilters(PipelineSpecControllerFilter)]
class PipelineSpecController
  include LF::HTTP::Controller

  @[LF::HTTP::Controller::Get("/pipeline")]
  @[LF::HTTP::UseGuards(PipelineSpecActionGuard)]
  @[LF::HTTP::UsePipes(PipelineSpecActionPipe)]
  @[LF::HTTP::UseInterceptors(PipelineSpecActionInterceptor)]
  def show(@[LF::HTTP::UsePipes(PipelineSpecParameterPipe)] value : String) : String
    PipelineSpecEvents.add("controller:show")
    value
  end

  @[LF::HTTP::Controller::Post("/pipeline/body")]
  def body(@[LF::HTTP::UsePipes(PipelineSpecJSONPipe)] payload : PipelineSpecPayload) : String
    PipelineSpecEvents.add("controller:body")
    payload.name
  end

  @[LF::HTTP::Controller::Get("/pipeline/failure")]
  @[LF::HTTP::UseFilters(PipelineSpecActionFilter)]
  def failure : String
    raise PipelineSpecFailure.new("broken")
  end

  @[LF::HTTP::Controller::Get("/pipeline/rejected")]
  @[LF::HTTP::UseGuards(PipelineSpecRejectGuard)]
  @[LF::HTTP::UseFilters(PipelineSpecForbiddenFilter)]
  def rejected : String
    PipelineSpecEvents.add("controller:rejected")
    "not reached"
  end

  @[LF::HTTP::Controller::Get("/pipeline/forbidden")]
  @[LF::HTTP::UseGuards(PipelineSpecRejectGuard)]
  def forbidden : String
    PipelineSpecEvents.add("controller:forbidden")
    "not reached"
  end

  @[LF::HTTP::Controller::Get("/pipeline/request-scope")]
  @[LF::HTTP::UseGuards(PipelineSpecRequestGuard)]
  def request_scope : String
    "request-scoped"
  end

  @[LF::HTTP::Controller::Get("/pipeline/short-circuit")]
  @[LF::HTTP::UseInterceptors(PipelineSpecShortCircuitInterceptor)]
  def short_circuit : String
    PipelineSpecEvents.add("controller:short-circuit")
    "not reached"
  end
end

private def pipeline_spec_app : {LF::HTTP::App, LF::DI::DefaultContainer}
  root = LF::DI::DefaultContainer.new
  root.register(LF::DI::ServiceConfiguration.new)
  root.add_bean(
    name: "pipeline_spec_request_guard",
    scope: "request",
    type: PipelineSpecRequestGuard
  ) do |_scope|
    PipelineSpecRequestGuard.new
  end
  app = LF::HTTP::App.new do |router|
    PipelineSpecController.setup_routes(router, root, PipelineSpecGlobals)
  end
  {app, root}
end

private def call_pipeline_spec_app(
  app : LF::HTTP::App,
  root : LF::DI::DefaultContainer,
  path : String,
  method = "GET",
  body : String? = nil,
) : HTTP::Client::Response
  io = IO::Memory.new
  headers = HTTP::Headers.new
  headers["Content-Type"] = "application/json" if body
  context = HTTP::Server::Context.new(
    HTTP::Request.new(method, path, headers, body),
    HTTP::Server::Response.new(io)
  )
  scope = root.enter_scope("request")
  context.dependency_scope = scope

  app.call(context)
  context.response.close
  scope.exit

  HTTP::Client::Response.from_io(IO::Memory.new(io.to_s))
end

describe LF::HTTP::ExecutionPipeline do
  it "runs guards, interceptors, pipes, and the controller in deterministic scope order" do
    PipelineSpecEvents.reset
    app, root = pipeline_spec_app

    response = call_pipeline_spec_app(app, root, "/pipeline?value=%20raw%20")

    response.status.should eq(HTTP::Status::OK)
    response.body.should eq("raw:controller:action:parameter")
    PipelineSpecEvents.values.should eq([
      "guard:global:PipelineSpecController#show",
      "guard:controller",
      "guard:action",
      "interceptor:global:before",
      "interceptor:controller:before",
      "interceptor:action:before",
      "pipe:global:query:String",
      "pipe:controller",
      "pipe:action",
      "pipe:parameter:value",
      "controller:show",
      "interceptor:action:after",
      "interceptor:controller:after",
      "interceptor:global:after",
    ])
    root.shutdown
  end

  it "applies JSON body pipes before typed deserialization" do
    PipelineSpecEvents.reset
    app, root = pipeline_spec_app

    response = call_pipeline_spec_app(app, root, "/pipeline/body", "POST", %({"name":"opal"}))

    response.status.should eq(HTTP::Status::OK)
    response.body.should eq("OPAL")
    PipelineSpecEvents.values.should contain("pipe:json:body")
    root.shutdown
  end

  it "uses the nearest matching exception filter first" do
    PipelineSpecEvents.reset
    app, root = pipeline_spec_app

    response = call_pipeline_spec_app(app, root, "/pipeline/failure")

    response.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    response.body.should eq("action:broken")
    PipelineSpecEvents.values.select(&.starts_with?("filter:")).should eq(["filter:action"])
    root.shutdown
  end

  it "lets filters handle guard failures before controller invocation" do
    PipelineSpecEvents.reset
    app, root = pipeline_spec_app

    response = call_pipeline_spec_app(app, root, "/pipeline/rejected")

    response.status.should eq(HTTP::Status::UNAUTHORIZED)
    response.body.should eq("login required")
    PipelineSpecEvents.values.should contain("guard:reject")
    PipelineSpecEvents.values.should contain("filter:forbidden")
    PipelineSpecEvents.values.should_not contain("controller:rejected")
    root.shutdown
  end

  it "maps an unhandled guard rejection to forbidden" do
    PipelineSpecEvents.reset
    app, root = pipeline_spec_app

    response = call_pipeline_spec_app(app, root, "/pipeline/forbidden")

    response.status.should eq(HTTP::Status::FORBIDDEN)
    response.body.should eq("Forbidden")
    PipelineSpecEvents.values.should_not contain("controller:forbidden")
    root.shutdown
  end

  it "allows an interceptor to short-circuit the action" do
    PipelineSpecEvents.reset
    app, root = pipeline_spec_app

    response = call_pipeline_spec_app(app, root, "/pipeline/short-circuit")

    response.status.should eq(HTTP::Status::OK)
    response.body.should eq("short-circuited")
    PipelineSpecEvents.values.should contain("interceptor:short-circuit")
    PipelineSpecEvents.values.should_not contain("controller:short-circuit")
    root.shutdown
  end

  it "resolves and disposes policies in the configured request scope" do
    PipelineSpecRequestGuard.reset
    app, root = pipeline_spec_app

    first = call_pipeline_spec_app(app, root, "/pipeline/request-scope")
    second = call_pipeline_spec_app(app, root, "/pipeline/request-scope")

    first.body.should eq("request-scoped")
    second.body.should eq("request-scoped")
    PipelineSpecRequestGuard.created.should eq(2)
    PipelineSpecRequestGuard.destroyed.should eq(2)
    root.shutdown
  end
end
