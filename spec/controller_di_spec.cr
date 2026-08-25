require "./spec_helper"
require "../src/opal"
require "http/client"

class ControllerDISpecService
  getter value : String

  def initialize(@value : String)
  end
end

class ControllerDISpecController
  include LF::HTTP::Controller
  include LF::DI::Disposable

  @instance : Int32

  @@instances = 0
  @@destroyed = 0

  def self.reset : Nil
    @@instances = 0
    @@destroyed = 0
  end

  def self.instances : Int32
    @@instances
  end

  def self.destroyed : Int32
    @@destroyed
  end

  def initialize(@controller_di_spec_service : ControllerDISpecService)
    @@instances += 1
    @instance = @@instances
  end

  @[LF::HTTP::Controller::Get("/constructor-di")]
  def show : String
    "#{@controller_di_spec_service.value}:#{@instance}"
  end

  @[LF::HTTP::Controller::Get("/constructor-di/:id")]
  def show_with_id(id : Int32) : String
    "#{@controller_di_spec_service.value}:#{id}"
  end

  def destroy : Nil
    @@destroyed += 1
  end
end

private def call_controller_app(app : LF::HTTP::App, root : LF::DI::DefaultContainer) : HTTP::Client::Response
  io = IO::Memory.new
  context = HTTP::Server::Context.new(
    HTTP::Request.new("GET", "/constructor-di"),
    HTTP::Server::Response.new(io)
  )
  scope = root.enter_scope("request")
  context.dependency_scope = scope

  app.call(context)
  context.response.close
  scope.exit

  HTTP::Client::Response.from_io(IO::Memory.new(io.to_s))
end

describe LF::HTTP::Controller do
  it "registers the controller as a request-scoped bean with constructor DI" do
    ControllerDISpecController.reset
    root = LF::DI::DefaultContainer.new
    root.add_bean(name: "controller_di_spec_service", type: ControllerDISpecService) do |_scope|
      ControllerDISpecService.new("injected")
    end
    app = LF::HTTP::App.new do |router|
      ControllerDISpecController.setup_routes(router, root)
    end

    first = call_controller_app(app, root)
    second = call_controller_app(app, root)

    first.body.should eq("injected:1")
    second.body.should eq("injected:2")
    ControllerDISpecController.instances.should eq(2)
    ControllerDISpecController.destroyed.should eq(2)
    root.shutdown
  end

  it "requires request scope middleware before resolving a controller" do
    root = LF::DI::DefaultContainer.new
    root.add_bean(name: "controller_di_spec_service", type: ControllerDISpecService) do |_scope|
      ControllerDISpecService.new("injected")
    end
    app = LF::HTTP::App.new do |router|
      ControllerDISpecController.setup_routes(router, root)
    end
    io = IO::Memory.new
    context = HTTP::Server::Context.new(
      HTTP::Request.new("GET", "/constructor-di"),
      HTTP::Server::Response.new(io)
    )

    app.call(context)
    context.response.close

    response = HTTP::Client::Response.from_io(IO::Memory.new(io.to_s))
    response.status.should eq(HTTP::Status::INTERNAL_SERVER_ERROR)
    response.body.should eq("DI context not initialized")
    root.shutdown
  end

  it "does not instantiate a controller when request binding fails" do
    ControllerDISpecController.reset
    root = LF::DI::DefaultContainer.new
    root.add_bean(name: "controller_di_spec_service", type: ControllerDISpecService) do |_scope|
      ControllerDISpecService.new("injected")
    end
    app = LF::HTTP::App.new do |router|
      ControllerDISpecController.setup_routes(router, root)
    end
    io = IO::Memory.new
    context = HTTP::Server::Context.new(
      HTTP::Request.new("GET", "/constructor-di/not-an-int"),
      HTTP::Server::Response.new(io)
    )
    context.dependency_scope = root.enter_scope("request")

    app.call(context)
    context.response.close

    response = HTTP::Client::Response.from_io(IO::Memory.new(io.to_s))
    response.status.should eq(HTTP::Status::BAD_REQUEST)
    ControllerDISpecController.instances.should eq(0)
    context.dependency_scope.not_nil!.exit
    root.shutdown
  end
end
