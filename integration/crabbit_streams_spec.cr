require "../spec/spec_helper"
require "../src/opal/microservices/crabbit_streams"

private alias MS = LF::Microservices

private STREAM_TEST_URL   = ENV["OPAL_RABBITMQ_STREAM_TEST_URL"]?
private STREAM_DELIVERIES = Channel(Tuple(String, UInt64, String)).new(16)

@[MS::StreamEventContract(
  namespace: "integration",
  service: "orders",
  contract_version: 1,
  event: "order_created",
  schema_version: 1,
)]
struct IntegrationOrderCreated
  include JSON::Serializable
  include MS::StreamEvent

  getter order_id : String

  def initialize(@order_id : String)
  end
end

class IntegrationOrdersStream
  include MS::StreamTopology
  stream "opal-integration-orders"
end

class IntegrationOrdersSuperStream
  include MS::StreamTopology
  super_stream "opal-integration-orders-super", 2
end

class IntegrationPoisonStream
  include MS::StreamTopology
  stream "opal-integration-poison"
end

@[LF::DI::Service]
@[MS::StreamHandler(
  topology: IntegrationOrdersStream,
  subscription: "opal_orders_projection",
)]
class IntegrationOrderProjection
  include MS::StreamProjection

  def handle(event : IntegrationOrderCreated, context : MS::StreamContext) : Nil
    metadata = context.stream_metadata.not_nil!
    STREAM_DELIVERIES.send({metadata.stream, metadata.offset, event.order_id})
  end
end

@[LF::DI::Service]
@[MS::StreamHandler(
  topology: IntegrationOrdersSuperStream,
  subscription: "opal_orders_super_projection",
)]
class IntegrationSuperOrderProjection
  include MS::StreamProjection

  def handle(event : IntegrationOrderCreated, context : MS::StreamContext) : Nil
    metadata = context.stream_metadata.not_nil!
    STREAM_DELIVERIES.send({metadata.stream, metadata.offset, event.order_id})
  end
end

@[LF::DI::Service]
@[MS::StreamHandler(
  topology: IntegrationPoisonStream,
  subscription: "opal_poison_projection",
)]
class IntegrationPoisonProjection
  include MS::StreamProjection

  @@fail = true

  def self.fail=(value : Bool) : Bool
    @@fail = value
  end

  def handle(event : IntegrationOrderCreated, context : MS::StreamContext) : Nil
    raise "poison projection" if @@fail
    metadata = context.stream_metadata.not_nil!
    STREAM_DELIVERIES.send({metadata.stream, metadata.offset, event.order_id})
  end
end

private def stream_application_context : Tuple(LF::DI::DefaultContainer, LF::ApplicationContext)
  container = LF::DI::DefaultContainer.new
  container.register(LF::DI::ServiceConfiguration.new)
  {container, LF::ApplicationContext.new(container)}
end

private def receive_stream_delivery(timeout_span : Time::Span = 10.seconds) : Tuple(String, UInt64, String)
  select
  when value = STREAM_DELIVERIES.receive
    value
  when timeout(timeout_span)
    raise "stream delivery timed out"
  end
end

private def wait_for_stream_offset(
  environment : Crabbit::Environment,
  subscription : String,
  stream : String,
  expected : UInt64,
  timeout_span : Time::Span = 10.seconds,
) : Nil
  deadline = Time.instant + timeout_span
  loop do
    return if environment.query_offset(subscription, stream) == expected
    raise "stream checkpoint timed out" if Time.instant >= deadline
    sleep 10.milliseconds
  end
end

if STREAM_TEST_URL
  describe "Crabbit StreamHandler integration" do
    it "publishes, projects, checkpoints, and resumes an ordinary stream" do
      environment = Crabbit::Environment.connect(STREAM_TEST_URL.not_nil!, load_balancer: true)
      definition = IntegrationOrdersStream.stream_definition
      environment.delete_stream(definition.name) if environment.stream_exists?(definition.name)
      container, context = stream_application_context
      registry = MS.compile_stream_handlers(IntegrationOrderProjection)
      settings = MS::StreamRuntimeSettings.new(
        create_topology: true,
        topology_refresh: 100.milliseconds,
      )
      runtime = MS::StreamHandlerRuntime.new(
        environment,
        registry,
        settings,
        topologies: [definition],
      )
      publisher = MS::StreamPublisher.new(environment, "opal-integration")
      runtime.configure(context)

      publisher.publish(
        IntegrationOrdersStream,
        IntegrationOrderCreated.new("order-1"),
      ).await
      first = receive_stream_delivery
      first[0].should eq(definition.name)
      first[2].should eq("order-1")
      wait_for_stream_offset(
        environment,
        "opal_orders_projection",
        definition.name,
        first[1],
      )

      runtime.quiesce(LF::ShutdownContext.new(Time.instant + 5.seconds))
      runtime.close

      publisher.publish(
        IntegrationOrdersStream,
        IntegrationOrderCreated.new("order-2"),
      ).await
      resumed = MS::StreamHandlerRuntime.new(
        environment,
        registry,
        settings,
        topologies: [definition],
      )
      resumed.configure(context)
      second = receive_stream_delivery
      second[2].should eq("order-2")
      second[1].should be > first[1]
    ensure
      resumed.try(&.close)
      runtime.try(&.close)
      publisher.try(&.close)
      if environment
        begin
          environment.delete_stream(IntegrationOrdersStream.stream_definition.name)
        rescue
        end
        environment.close
      end
      container.try(&.shutdown)
    end

    it "routes and checkpoints events across super-stream partitions" do
      environment = Crabbit::Environment.connect(STREAM_TEST_URL.not_nil!, load_balancer: true)
      definition = IntegrationOrdersSuperStream.stream_definition
      begin
        environment.delete_super_stream(definition.name)
      rescue
      end
      container, context = stream_application_context
      registry = MS.compile_stream_handlers(IntegrationSuperOrderProjection)
      runtime = MS::StreamHandlerRuntime.new(
        environment,
        registry,
        MS::StreamRuntimeSettings.new(
          create_topology: true,
          topology_refresh: 100.milliseconds,
        ),
        topologies: [definition],
      )
      publisher = MS::StreamPublisher.new(environment, "opal-integration-super")
      runtime.configure(context)

      publisher.publish(
        IntegrationOrdersSuperStream,
        IntegrationOrderCreated.new("order-super"),
        routing_key: "customer-42",
      ).await
      delivery = receive_stream_delivery
      definition.partition_names.should contain(delivery[0])
      delivery[2].should eq("order-super")
      wait_for_stream_offset(
        environment,
        "opal_orders_super_projection",
        delivery[0],
        delivery[1],
      )
    ensure
      runtime.try(&.close)
      publisher.try(&.close)
      if environment
        begin
          environment.delete_super_stream(IntegrationOrdersSuperStream.stream_definition.name)
        rescue
        end
        environment.close
      end
      container.try(&.shutdown)
    end

    it "stops a poison partition without advancing its checkpoint and resumes it explicitly" do
      environment = Crabbit::Environment.connect(STREAM_TEST_URL.not_nil!, load_balancer: true)
      definition = IntegrationPoisonStream.stream_definition
      environment.delete_stream(definition.name) if environment.stream_exists?(definition.name)
      container, context = stream_application_context
      registry = MS.compile_stream_handlers(IntegrationPoisonProjection)
      runtime = MS::StreamHandlerRuntime.new(
        environment,
        registry,
        MS::StreamRuntimeSettings.new(
          create_topology: true,
          retry_policy: MS::StreamRetryPolicy.new(
            max_attempts: 2,
            initial_delay: 1.millisecond,
            max_delay: 1.millisecond,
          ),
        ),
        topologies: [definition],
      )
      publisher = MS::StreamPublisher.new(environment, "opal-integration-poison")
      IntegrationPoisonProjection.fail = true
      runtime.configure(context)
      publisher.publish(
        IntegrationPoisonStream,
        IntegrationOrderCreated.new("poison-order"),
      ).await

      deadline = Time.instant + 10.seconds
      until runtime.status.degraded?
        raise "poison partition did not degrade" if Time.instant >= deadline
        sleep 10.milliseconds
      end
      failure = runtime.failures.first
      failure.offset.should eq(0_u64)
      failure.attempts.should eq(2)
      environment.query_offset("opal_poison_projection", definition.name).should be_nil

      IntegrationPoisonProjection.fail = false
      runtime.resume(
        definition.name,
        "opal_poison_projection",
        definition.name,
      ).should be_true
      delivered = receive_stream_delivery
      delivered[2].should eq("poison-order")
      wait_for_stream_offset(
        environment,
        "opal_poison_projection",
        definition.name,
        delivered[1],
      )
    ensure
      runtime.try(&.close)
      publisher.try(&.close)
      if environment
        begin
          environment.delete_stream(IntegrationPoisonStream.stream_definition.name)
        rescue
        end
        environment.close
      end
      container.try(&.shutdown)
      IntegrationPoisonProjection.fail = true
    end
  end
else
  describe "Crabbit StreamHandler integration" do
    pending "requires OPAL_RABBITMQ_STREAM_TEST_URL" do
    end
  end
end
