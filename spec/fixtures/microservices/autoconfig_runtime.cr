require "../../../src/opal/autoconfig/microservices/rabbitmq"

alias MS = LF::Microservices
alias RMQ = LF::Microservices::RabbitMQ

struct RuntimeAutoRequest
  include JSON::Serializable

  getter value : String

  def initialize(@value : String)
  end
end

struct RuntimeAutoResponse
  include JSON::Serializable

  getter value : String

  def initialize(@value : String)
  end
end

class RuntimeAutoMessages
  include MS::MessageController

  @[MS::RPC(method: "echo", schema_version: 1)]
  def echo(request : RuntimeAutoRequest) : RuntimeAutoResponse
    RuntimeAutoResponse.new(request.value)
  end
end

class RuntimeAutoClient
  include MS::TypedServiceClient

  service "spec", "echo", 1
  rpc echo, RuntimeAutoRequest, RuntimeAutoResponse, "echo", 1
end

@[LF::Application]
@[LF::AutoConfig::Microservices(
  namespace: "spec",
  service: "echo",
  contract_version: 1,
  controllers: [RuntimeAutoMessages],
  clients: [RuntimeAutoClient],
)]
class RuntimeAutoApplication
end

class RuntimeAutoSession < RMQ::Session
  getter exchanges = [] of String
  getter queues = [] of String
  getter consumers = [] of String
  getter? closed = false

  def declare_exchange(name : String, type : String, durable : Bool = true) : Nil
    @exchanges << name
  end

  def declare_queue(name : String, options : RMQ::QueueOptions) : String
    @queues << name
    name
  end

  def bind_queue(queue : String, exchange : String, routing_key : String) : Nil
  end

  def consume(
    queue : String,
    tag : String,
    prefetch : UInt16,
    work_pool : Int32,
    &callback : RMQ::BrokerDelivery -> Nil
  ) : String
    @consumers << queue
    tag
  end

  def cancel(consumer_tag : String) : Nil
  end

  def publish(
    exchange : String,
    publication : MS::Publication,
    persistent : Bool,
  ) : RMQ::PublishResult
    RMQ::PublishResult.new(true, true)
  end

  def ack(token : UInt64) : Nil
  end

  def reject(token : UInt64, requeue : Bool) : Nil
  end

  def on_disconnect(&callback : Exception -> Nil) : Nil
  end

  def closed? : Bool
    @closed
  end

  def close : Nil
    @closed = true
  end
end

def runtime_with_config(path : String) : LF::ApplicationRuntime
  root = LF::DI::DefaultContainer.new
  root.add_bean(name: "config_service", type: LF::ConfigService) do |_scope|
    LF::ConfigService.new(path)
  end
  LF::ApplicationRuntime.new(root)
end

path = "/tmp/opal-microservices-autoconfig-runtime-#{Process.pid}.yml"

begin
  File.write(path, <<-YAML)
  microservices:
    transport: rabbitmq
    topology:
      rpc_exchange: spec.rpc
      rpc_queue_prefix: spec.rpc.queue
      reply_queue_prefix: spec.reply
    rabbitmq:
      url: amqp://ignored-by-fake
      prefetch: 9
      work_pool: 3
    client:
      max_pending: 17
      max_replies: 19
  YAML

  server_session = RuntimeAutoSession.new
  client_session = RuntimeAutoSession.new
  runtime = runtime_with_config(path)
  extension = MS::AutoConfig::Extension.new(
    server_session_factory: -> { server_session.as(RMQ::Session) },
    client_session_factory: -> { client_session.as(RMQ::Session) },
  )
  runtime.install(extension)

  raise "extension was not configured" unless extension.configured?
  server = extension.server_runtime.not_nil!
  raise "wrong local service" unless server.service == MS::ServiceIdentity.new("spec", "echo", 1)
  raise "handler registry was not compiled" unless server.registry.rpc_handlers.map(&.target.method) == ["echo"]
  raise "server transport did not start" unless server.transport.status.running?
  raise "wrong RPC pending bound" unless extension.rpc_client.not_nil!.max_pending == 17
  reply_route = extension.client_transport.not_nil!.reply_to.value
  raise "configured reply prefix was ignored" unless reply_route.starts_with?("spec.reply.")
  resolved_client = runtime.resolve(RuntimeAutoClient)
  raise "typed client did not share RPCClient" unless resolved_client.rpc_client.same?(extension.rpc_client.not_nil!)
  raise "server topology was not declared" unless server_session.exchanges.includes?("spec.rpc")
  raise "server consumer did not start" unless server_session.consumers.includes?("spec.rpc.queue.spec.echo.v1")
  raise "client topology was not declared" unless client_session.exchanges.includes?("spec.rpc")
  raise "reply queue was not declared" unless client_session.queues.first.starts_with?("spec.reply.")

  runtime.shutdown
  raise "extension did not stop" unless extension.stopped?
  raise "server session did not close" unless server_session.closed?
  raise "client session did not close" unless client_session.closed?

  File.write(path, <<-YAML)
  microservices:
    transport: kafka
    rabbitmq:
      url: amqp://ignored-by-fake
  YAML
  invalid_runtime = runtime_with_config(path)
  invalid_extension = MS::AutoConfig::Extension.new
  rejected = false
  begin
    invalid_runtime.install(invalid_extension)
  rescue error : MS::AutoConfig::ConfigurationError
    rejected = error.message.try(&.includes?("must be rabbitmq")) || false
  end
  raise "invalid transport was not rejected" unless rejected
  raise "failed extension was not stopped" unless invalid_extension.stopped?

  puts "microservices autoconfiguration runtime ok"
ensure
  File.delete(path) if File.exists?(path)
end
