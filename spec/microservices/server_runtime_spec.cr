require "../spec_helper"
require "../../src/opal/microservices"

private alias MS = LF::Microservices

private struct RuntimeCommand
  include JSON::Serializable

  getter value : String
  getter fail : Bool

  def initialize(@value : String, @fail : Bool = false)
  end
end

private struct RuntimeResult
  include JSON::Serializable

  getter value : String

  def initialize(@value : String)
  end
end

private class RuntimeScopedDependency
  include LF::DI::Disposable

  class_property destroyed = 0

  def destroy : Nil
    self.class.destroyed += 1
  end
end

private class RuntimeMessages
  include MS::MessageController

  class_property event_attempts = 0
  class_property event_failures_remaining = 0

  def initialize(@dependency : RuntimeScopedDependency)
  end

  @[MS::RPC(method: "execute", schema_version: 1)]
  def execute(command : RuntimeCommand) : RuntimeResult
    raise "private database detail" if command.fail
    RuntimeResult.new(command.value.upcase)
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
  def stock_changed(command : RuntimeCommand) : Nil
    self.class.event_attempts += 1
    if self.class.event_failures_remaining > 0
      self.class.event_failures_remaining -= 1
      raise MS::MessageRetryableError.new("temporary private detail")
    end
  end
end

private def runtime_service : MS::ServiceIdentity
  MS::ServiceIdentity.new("shop", "catalog", 1)
end

private def runtime_target : MS::RPCTarget
  MS::RPCTarget.new(runtime_service, "execute", 1)
end

private def runtime_request(
  client : MS::InMemoryClientTransport,
  codec : MS::JSONCodec,
  now : Time,
  command : RuntimeCommand,
) : MS::Publication
  envelope = MS::RPCRequestEnvelope.new(
    UUID.random,
    runtime_service,
    "execute",
    1,
    now - 1.second,
    now + 5.seconds,
    UUID.random,
    client.reply_to,
    payload: JSON.parse(command.to_json),
  )
  MS::Publication.new(
    envelope.message_id,
    runtime_target.routing_key,
    codec.encode_request(envelope),
    mandatory: true,
    correlation_id: envelope.correlation_id,
    reply_to: envelope.reply_to,
    expires_at: envelope.deadline_at,
    content_type: codec.profile.rpc_content_type,
  )
end

private def runtime_application(
  broker : MS::InMemoryBroker,
  codec : MS::JSONCodec,
  now : Time,
) : Tuple(LF::ApplicationRuntime, MS::InMemoryServerTransport, MS::ServerRuntime)
  root = LF::DI::DefaultContainer.new
  root.add_bean(
    name: "runtime_scoped_dependency",
    scope: "message",
    type: RuntimeScopedDependency,
  ) { RuntimeScopedDependency.new }
  application = LF::ApplicationRuntime.new(root)
  server = MS::InMemoryServerTransport.new(broker, runtime_service)
  extension = application.install(
    MS::ServerRuntime.new(
      runtime_service,
      server,
      codec,
      clock: -> { now },
    ) do |context|
      MS.compile_executable_handlers(runtime_service, context, RuntimeMessages)
    end
  )
  {application, server, extension}
end

describe MS::ServerRuntime do
  it "installs explicit controllers with the convenience macro" do
    root = LF::DI::DefaultContainer.new
    root.add_bean(
      name: "runtime_scoped_dependency",
      scope: "message",
      type: RuntimeScopedDependency,
    ) { RuntimeScopedDependency.new }
    application = LF::ApplicationRuntime.new(root)
    broker = MS::InMemoryBroker.new
    server = MS::InMemoryServerTransport.new(broker, runtime_service)

    extension = MS.install_server(application, runtime_service, server, RuntimeMessages)

    extension.configured?.should be_true
    extension.registry.rpc_handlers.map(&.target.method).should eq(["execute"])
    server.status.running?.should be_true
  ensure
    application.try { |current| current.shutdown unless current.closed? }
  end

  it "drains accepted RPC work through the application lifecycle" do
    now = Time.utc(2026, 1, 1, 12)
    codec = MS::JSONCodec.new
    broker = MS::InMemoryBroker.new(-> { now })
    application, server, extension = runtime_application(broker, codec, now)
    client = MS::InMemoryClientTransport.new(broker)
    client.start
    RuntimeScopedDependency.destroyed = 0

    publication = runtime_request(client, codec, now, RuntimeCommand.new("opal"))
    client.publish_rpc(runtime_target, publication)
    server.pending_count.should eq(1)

    application.shutdown(timeout: 1.second)

    response = codec.decode_response(client.next_reply.as(MS::EncodedDelivery).body)
    response.success?.should be_true
    response.result.not_nil!["value"].as_s.should eq("OPAL")
    RuntimeScopedDependency.destroyed.should eq(1)
    extension.stopped?.should be_true
    server.status.closed?.should be_true
  ensure
    client.try(&.close)
    application.try { |current| current.shutdown unless current.closed? }
  end

  it "publishes a sanitized RPC failure and acknowledges the request" do
    now = Time.utc(2026, 1, 1, 12)
    codec = MS::JSONCodec.new
    broker = MS::InMemoryBroker.new(-> { now })
    application, server, extension = runtime_application(broker, codec, now)
    client = MS::InMemoryClientTransport.new(broker)
    client.start

    publication = runtime_request(client, codec, now, RuntimeCommand.new("opal", fail: true))
    client.publish_rpc(runtime_target, publication)
    server.dispatch_one
    response = codec.decode_response(client.next_reply.as(MS::EncodedDelivery).body)

    response.success?.should be_false
    response.error.not_nil!.code.should eq("internal_error")
    response.error.not_nil!.message.should eq("The service could not complete the request.")
    response.error.not_nil!.message.should_not contain("database")
    server.pending_count.should eq(0)
    server.inflight_count.should eq(0)
  ensure
    client.try(&.close)
    application.try { |current| current.shutdown unless current.closed? }
  end

  it "derives subscriptions and retries explicitly retryable events" do
    now = Time.utc(2026, 1, 1, 12)
    codec = MS::JSONCodec.new
    broker = MS::InMemoryBroker.new(-> { now })
    application, server, extension = runtime_application(broker, codec, now)
    client = MS::InMemoryClientTransport.new(broker)
    client.start(receive_replies: false)
    RuntimeMessages.event_attempts = 0
    RuntimeMessages.event_failures_remaining = 1

    identity = MS::EventIdentity.new(
      MS::ServiceIdentity.new("warehouse", "inventory", 1),
      "stock-changed",
      1,
    )
    subscriptions = server.matching_subscriptions(identity)
    subscriptions.size.should eq(1)
    subscription = subscriptions.first
    subscription.destination.should eq(runtime_service)
    subscription.subscription.should eq("catalog-projector")

    envelope = MS::EventEnvelope.new(
      UUID.random,
      identity.source,
      identity.event,
      identity.schema_version,
      now,
      payload: JSON.parse(RuntimeCommand.new("opal").to_json),
    )
    client.publish_event(identity, MS::Publication.new(
      envelope.message_id,
      identity.routing_key,
      codec.encode_event(envelope),
      mandatory: true,
      content_type: codec.profile.event_content_type,
    ))

    server.dispatch_one
    server.pending_count.should eq(1)
    server.dispatch_one
    RuntimeMessages.event_attempts.should eq(2)
    server.pending_count.should eq(0)
    server.inflight_count.should eq(0)
  ensure
    client.try(&.close)
    application.try { |current| current.shutdown unless current.closed? }
  end

  it "preserves the runtime after a drain deadline and allows shutdown retry" do
    now = Time.utc(2026, 1, 1, 12)
    codec = MS::JSONCodec.new
    broker = MS::InMemoryBroker.new(-> { now })
    application, server, extension = runtime_application(broker, codec, now)
    client = MS::InMemoryClientTransport.new(broker)
    client.start(receive_replies: false)
    RuntimeMessages.event_attempts = 0
    RuntimeMessages.event_failures_remaining = Int32::MAX

    identity = MS::EventIdentity.new(
      MS::ServiceIdentity.new("warehouse", "inventory", 1),
      "stock-changed",
      1,
    )
    envelope = MS::EventEnvelope.new(
      UUID.random,
      identity.source,
      identity.event,
      identity.schema_version,
      now,
      payload: JSON.parse(RuntimeCommand.new("opal").to_json),
    )
    client.publish_event(identity, MS::Publication.new(
      envelope.message_id,
      identity.routing_key,
      codec.encode_event(envelope),
      mandatory: true,
      content_type: codec.profile.event_content_type,
    ))

    error = expect_raises(LF::ApplicationRuntime::ShutdownError) do
      application.shutdown(timeout: 1.millisecond)
    end
    error.extension_errors.first.should be_a(MS::DrainTimeoutError)
    application.shutdown_pending?.should be_true
    application.closed?.should be_false
    extension.stopped?.should be_false
    server.status.quiescing?.should be_true

    RuntimeMessages.event_failures_remaining = 0
    application.shutdown(timeout: 1.second)
    application.closed?.should be_true
    extension.stopped?.should be_true
  ensure
    RuntimeMessages.event_failures_remaining = 0
    client.try(&.close)
    application.try { |current| current.shutdown unless current.closed? }
  end

  it "rejects a registry compiled for another service before intake" do
    local = runtime_service
    foreign = MS::ServiceIdentity.new("shop", "orders", 1)
    broker = MS::InMemoryBroker.new
    server = MS::InMemoryServerTransport.new(broker, local)
    root = LF::DI::DefaultContainer.new
    root.add_bean(
      name: "runtime_scoped_dependency",
      scope: "message",
      type: RuntimeScopedDependency,
    ) { RuntimeScopedDependency.new }
    application = LF::ApplicationRuntime.new(root)
    extension = MS::ServerRuntime.new(local, server) do |context|
      MS.compile_executable_handlers(foreign, context, RuntimeMessages)
    end

    expect_raises(MS::RuntimeConfigurationError, "do not belong") do
      application.install(extension)
    end
    server.status.closed?.should be_true
    application.closed?.should be_true
  ensure
    application.try { |current| current.shutdown unless current.closed? }
  end
end
