require "../spec_helper"
require "../../src/opal/microservices"

private alias MS = LF::Microservices

private struct TypedClientRequest
  include JSON::Serializable

  getter value : String
  getter fail : Bool

  def initialize(@value : String, @fail : Bool = false)
  end
end

private struct TypedClientResponse
  include JSON::Serializable

  getter value : String

  def initialize(@value : String)
  end
end

private class TypedClientGuard < MS::Guard
  class_property headers = {} of String => JSON::Any
  class_property causation_id : UUID?

  def can_activate(context : MS::ExecutionContext) : Bool
    self.class.headers = context.headers
    self.class.causation_id = context.causation_id
    true
  end
end

@[MS::UseGuards(TypedClientGuard)]
private class TypedClientMessages
  include MS::MessageController

  @[MS::RPC(method: "echo", schema_version: 1)]
  def echo(request : TypedClientRequest) : TypedClientResponse
    raise "private server failure" if request.fail
    TypedClientResponse.new(request.value.upcase)
  end

  @[MS::RPC(method: "ping", schema_version: 1)]
  def ping(request : TypedClientRequest) : Nil
  end
end

private class CatalogServiceClient
  include MS::TypedServiceClient

  service "shop", "catalog", 1
  rpc echo, TypedClientRequest, TypedClientResponse, "echo", 1
  rpc ping, TypedClientRequest, Nil, "ping", 1
end

private class FailingClientTransport < MS::ClientTransport
  @status = MS::TransportStatus::Running
  getter generation : Int64 = 1_i64
  getter reply_to : MS::ReplyRoute = MS::ReplyRoute.new("reply.0123456789abcdef0123456789abcdef")

  def status : MS::TransportStatus
    @status
  end

  def start(receive_replies : Bool = true) : Nil
  end

  def publish_rpc(target : MS::RPCTarget, publication : MS::Publication) : MS::PublicationReceipt
    raise MS::TransportUnavailableError.new("connection unavailable")
  end

  def publish_event(identity : MS::EventIdentity, publication : MS::Publication) : MS::PublicationReceipt
    raise MS::TransportUnavailableError.new("connection unavailable")
  end

  def next_reply? : MS::EncodedDelivery | MS::ReplyProtocolFailure | Nil
    nil
  end

  def cancel_pending(correlation_id : UUID) : Nil
  end

  def reconnect : Array(UUID)
    [] of UUID
  end

  def close : Nil
    @status = MS::TransportStatus::Closed
  end
end

private class TypedRPCFixture
  getter now = Time.utc(2026, 1, 1, 12)
  getter service = MS::ServiceIdentity.new("shop", "catalog", 1)
  getter codec = MS::JSONCodec.new
  getter broker : MS::InMemoryBroker
  getter server : MS::InMemoryServerTransport
  getter transport : MS::InMemoryClientTransport
  getter rpc : MS::RPCClient
  getter client : CatalogServiceClient
  getter application : LF::ApplicationRuntime

  def initialize(
    max_pending : Int32 = 1_024,
    error_mapper : MS::RPCErrorMapper? = nil,
  )
    @broker = MS::InMemoryBroker.new(-> { now })
    @server = MS::InMemoryServerTransport.new(@broker, service)
    root = LF::DI::DefaultContainer.new
    root.add_bean(name: "typed_client_guard", scope: "message", type: TypedClientGuard) do
      TypedClientGuard.new
    end
    @application = LF::ApplicationRuntime.new(root)
    mapper = error_mapper || MS::RPCErrorMapper.new do |error|
      MS::ServerRuntime.default_rpc_error(error)
    end
    @application.install(
      MS::ServerRuntime.new(
        service,
        @server,
        codec,
        clock: -> { now },
        rpc_error_mapper: mapper,
      ) do |context|
        MS.compile_executable_handlers(service, context, TypedClientMessages)
      end
    )
    @transport = MS::InMemoryClientTransport.new(@broker)
    @transport.start
    @rpc = MS::RPCClient.new(
      @transport,
      codec,
      max_pending: max_pending,
      clock: -> { now },
    )
    @client = CatalogServiceClient.new(@rpc)
  end

  def dispatch_next : Nil
    spawn do
      loop do
        if server.pending_count > 0
          server.dispatch_one
          break
        end
        Fiber.yield
      end
    end
  end

  def close : Nil
    application.shutdown(timeout: 1.second) unless application.closed?
    rpc.close unless rpc.closed?
  end
end

describe MS::RPCClient do
  it "executes an explicitly declared typed service method" do
    fixture = TypedRPCFixture.new
    causation_id = UUID.random
    TypedClientGuard.headers = {} of String => JSON::Any
    TypedClientGuard.causation_id = nil
    fixture.dispatch_next

    result = fixture.client.echo(
      TypedClientRequest.new("opal"),
      headers: {"tenant" => JSON::Any.new("acme")},
      causation_id: causation_id,
    )

    result.value.should eq("OPAL")
    fixture.client.service.should eq(fixture.service)
    TypedClientGuard.headers["tenant"].as_s.should eq("acme")
    TypedClientGuard.causation_id.should eq(causation_id)
    fixture.rpc.pending_count.should eq(0)
    fixture.transport.pending_count.should eq(0)
  ensure
    fixture.try(&.close)
  end

  it "supports typed Nil responses" do
    fixture = TypedRPCFixture.new
    fixture.dispatch_next

    fixture.client.ping(TypedClientRequest.new("opal")).should be_nil
  ensure
    fixture.try(&.close)
  end

  it "demultiplexes concurrent replies by correlation ID" do
    fixture = TypedRPCFixture.new
    results = Channel(Tuple(String, String)).new
    {"first", "second"}.each do |value|
      spawn do
        response = fixture.client.echo(TypedClientRequest.new(value), timeout: 1.second)
        results.send({value, response.value})
      end
    end
    until fixture.server.pending_count == 2
      Fiber.yield
    end

    fixture.server.dispatch_one
    fixture.server.dispatch_one
    received = {results.receive, results.receive}.to_a.to_h

    received.should eq({"first" => "FIRST", "second" => "SECOND"})
    fixture.rpc.pending_count.should eq(0)
  ensure
    fixture.try(&.close)
  end

  it "raises a sanitized remote public error" do
    mapper = MS::RPCErrorMapper.new do |error|
      MS::RemoteRPCErrorData.new(
        "catalog_failure",
        "Catalog could not process the request.",
        details: {"safe" => JSON::Any.new(true)},
      )
    end
    fixture = TypedRPCFixture.new(error_mapper: mapper)
    fixture.dispatch_next

    error = expect_raises(MS::RPCRemoteError) do
      fixture.client.echo(TypedClientRequest.new("opal", fail: true))
    end

    error.code.should eq("catalog_failure")
    error.message.should eq("Catalog could not process the request.")
    error.details["safe"].as_bool.should be_true
    error.message.not_nil!.should_not contain("private")
    error.retryable?.should be_false
  ensure
    fixture.try(&.close)
  end

  it "distinguishes an unroutable rejection before acceptance" do
    broker = MS::InMemoryBroker.new
    transport = MS::InMemoryClientTransport.new(broker)
    transport.start
    rpc = MS::RPCClient.new(transport)
    client = CatalogServiceClient.new(rpc)

    error = expect_raises(MS::RPCRejectedError) do
      client.echo(TypedClientRequest.new("opal"))
    end

    error.target.should eq(MS::RPCTarget.new(client.service, "echo", 1))
    rpc.pending_count.should eq(0)
    transport.pending_count.should eq(0)
  ensure
    rpc.try { |current| current.close unless current.closed? }
  end

  it "distinguishes transport failure before acceptance" do
    transport = FailingClientTransport.new
    rpc = MS::RPCClient.new(transport)
    client = CatalogServiceClient.new(rpc)

    error = expect_raises(MS::RPCTransportError) do
      client.echo(TypedClientRequest.new("opal"))
    end

    error.cause.should be_a(MS::TransportUnavailableError)
    rpc.pending_count.should eq(0)
  ensure
    rpc.try { |current| current.close unless current.closed? }
  end

  it "times out an accepted call without replaying it" do
    fixture = TypedRPCFixture.new

    error = expect_raises(MS::RPCTimeoutError) do
      fixture.client.echo(TypedClientRequest.new("opal"), timeout: 2.milliseconds)
    end

    error.message.not_nil!.should contain("may still have occurred")
    fixture.server.pending_count.should eq(1)
    fixture.rpc.pending_count.should eq(0)
    fixture.transport.pending_count.should eq(0)
  ensure
    fixture.try(&.close)
  end

  it "rejects non-positive deadlines before publication" do
    fixture = TypedRPCFixture.new

    expect_raises(ArgumentError, "timeout must be positive") do
      fixture.client.echo(TypedClientRequest.new("opal"), timeout: 0.seconds)
    end
    fixture.server.pending_count.should eq(0)
    fixture.rpc.pending_count.should eq(0)
  ensure
    fixture.try(&.close)
  end

  it "marks accepted calls outcome-unknown across reply-route reconnect" do
    fixture = TypedRPCFixture.new
    result = Channel(Exception).new
    spawn do
      begin
        fixture.client.echo(TypedClientRequest.new("opal"), timeout: 1.second)
      rescue error : Exception
        result.send(error)
      end
    end
    until fixture.server.pending_count == 1
      Fiber.yield
    end
    original_route = fixture.transport.reply_to

    canceled = fixture.rpc.reconnect
    error = result.receive

    canceled.size.should eq(1)
    error.should be_a(MS::RPCOutcomeUnknownError)
    fixture.transport.generation.should eq(2)
    fixture.transport.reply_to.should_not eq(original_route)
    fixture.server.pending_count.should eq(1)
  ensure
    fixture.try(&.close)
  end

  it "enforces its own pending call bound before transport publication" do
    fixture = TypedRPCFixture.new(max_pending: 1)
    first_result = Channel(Exception).new
    spawn do
      begin
        fixture.client.echo(TypedClientRequest.new("first"), timeout: 1.second)
      rescue error : Exception
        first_result.send(error)
      end
    end
    until fixture.rpc.pending_count == 1
      Fiber.yield
    end

    expect_raises(MS::RPCRejectedError) do
      fixture.client.echo(TypedClientRequest.new("second"))
    end
    fixture.server.pending_count.should eq(1)

    fixture.rpc.reconnect
    first_result.receive.should be_a(MS::RPCOutcomeUnknownError)
  ensure
    fixture.try(&.close)
  end

  it "rejects a reply whose result does not match the declared response DTO" do
    now = Time.utc(2026, 1, 1, 12)
    codec = MS::JSONCodec.new
    broker = MS::InMemoryBroker.new(-> { now })
    service = MS::ServiceIdentity.new("shop", "catalog", 1)
    server = MS::InMemoryServerTransport.new(broker, service)
    server.prepare(["echo"], [] of MS::EventSubscription)
    server.start(->(delivery : MS::EncodedDelivery) {
      response = MS::RPCResponseEnvelope.success(
        UUID.random,
        delivery.correlation_id.not_nil!,
        now,
        JSON::Any.new("not-an-object"),
      )
      server.publish_reply(MS::Publication.new(
        response.message_id,
        delivery.reply_to.not_nil!.value,
        codec.encode_response(response),
        mandatory: true,
        correlation_id: response.correlation_id,
        content_type: codec.profile.rpc_content_type,
      ))
      MS::SettlementRecommendation::Ack
    })
    transport = MS::InMemoryClientTransport.new(broker)
    transport.start
    rpc = MS::RPCClient.new(transport, codec, clock: -> { now })
    client = CatalogServiceClient.new(rpc)
    spawn do
      loop do
        if server.pending_count > 0
          server.dispatch_one
          break
        end
        Fiber.yield
      end
    end

    expect_raises(MS::RPCProtocolError, "does not match TypedClientResponse") do
      client.echo(TypedClientRequest.new("opal"))
    end
  ensure
    rpc.try { |current| current.close unless current.closed? }
    server.try(&.close)
  end
end
