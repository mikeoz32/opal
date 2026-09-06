require "../spec_helper"
require "../../src/opal/microservices/rabbitmq"

private alias MS = LF::Microservices
private alias RMQ = LF::Microservices::RabbitMQ

private alias RabbitExchangeDeclaration = Tuple(String, String, Bool)
private alias RabbitBinding = Tuple(String, String, String)
private alias RabbitConsumer = Tuple(String, String, UInt16, Int32)
private alias RabbitPublication = Tuple(String, MS::Publication, Bool)
private alias RabbitRejection = Tuple(UInt64, Bool)

private class RabbitFakeSession < RMQ::Session
  getter exchanges = [] of RabbitExchangeDeclaration
  getter queues = {} of String => RMQ::QueueOptions
  getter bindings = [] of RabbitBinding
  getter consumers = [] of RabbitConsumer
  getter publications = [] of RabbitPublication
  getter acknowledgements = [] of UInt64
  getter rejections = [] of RabbitRejection
  getter cancellations = [] of String
  getter closed = false

  @callbacks = {} of String => RMQ::DeliveryCallback
  @publish_results = Deque(RMQ::PublishResult).new
  @disconnect_callback : RMQ::DisconnectCallback?
  @publish_error : Exception?

  def declare_exchange(name : String, type : String, durable : Bool = true) : Nil
    @exchanges << {name, type, durable}
  end

  def declare_queue(name : String, options : RMQ::QueueOptions) : String
    @queues[name] = options
    name
  end

  def bind_queue(queue : String, exchange : String, routing_key : String) : Nil
    @bindings << {queue, exchange, routing_key}
  end

  def consume(
    queue : String,
    tag : String,
    prefetch : UInt16,
    work_pool : Int32,
    &callback : RMQ::BrokerDelivery -> Nil
  ) : String
    @consumers << {queue, tag, prefetch, work_pool}
    @callbacks[queue] = callback
    tag
  end

  def cancel(consumer_tag : String) : Nil
    @cancellations << consumer_tag
  end

  def publish(
    exchange : String,
    publication : MS::Publication,
    persistent : Bool,
  ) : RMQ::PublishResult
    raise @publish_error.not_nil! if @publish_error
    @publications << {exchange, publication, persistent}
    @publish_results.shift? || RMQ::PublishResult.new(true, true)
  end

  def ack(token : UInt64) : Nil
    @acknowledgements << token
  end

  def reject(token : UInt64, requeue : Bool) : Nil
    @rejections << {token, requeue}
  end

  def on_disconnect(&callback : Exception -> Nil) : Nil
    @disconnect_callback = callback
  end

  def closed? : Bool
    @closed
  end

  def close : Nil
    @closed = true
  end

  def enqueue_publish_result(confirmed : Bool, routed : Bool) : Nil
    @publish_results << RMQ::PublishResult.new(confirmed, routed)
  end

  def fail_publish(error : Exception) : Nil
    @publish_error = error
  end

  def deliver(queue : String, delivery : RMQ::BrokerDelivery) : Nil
    callback = @callbacks[queue]? || raise "no consumer for #{queue}"
    callback.call(delivery)
  end

  def disconnect(error : Exception = Exception.new("connection lost")) : Nil
    @closed = true
    @disconnect_callback.try(&.call(error))
  end
end

private def rabbit_service : MS::ServiceIdentity
  MS::ServiceIdentity.new("shop", "catalog", 1)
end

private def rabbit_target : MS::RPCTarget
  MS::RPCTarget.new(rabbit_service, "find", 1)
end

private def rabbit_settings(
  max_attempts : Int32 = 3,
  max_queue_length : Int32 = 100,
) : RMQ::Settings
  RMQ::Settings.new(
    "amqp://guest:guest@127.0.0.1:5672",
    prefetch: 7,
    work_pool: 2,
    max_attempts: max_attempts,
    max_queue_length: max_queue_length,
    retry_delay: 250.milliseconds,
  )
end

private def rabbit_factory(session : RabbitFakeSession) : RMQ::SessionFactory
  -> { session.as(RMQ::Session) }
end

private def rabbit_rpc_publication(
  client : RMQ::ClientTransport,
  correlation_id : UUID = UUID.random,
) : MS::Publication
  MS::Publication.new(
    UUID.random,
    rabbit_target.routing_key,
    Bytes[1, 2, 3],
    mandatory: true,
    correlation_id: correlation_id,
    reply_to: client.reply_to,
    expires_at: Time.utc(2026, 1, 1, 12, 0, 5),
    content_type: "application/json",
  )
end

private def rabbit_broker_delivery(
  routing_key : String = rabbit_target.routing_key,
  token : UInt64 = 1_u64,
  message_id : UUID = UUID.random,
  correlation_id : UUID? = UUID.random,
  reply_to : MS::ReplyRoute? = MS::ReplyRoute.generate,
  headers : Hash(String, JSON::Any) = {} of String => JSON::Any,
  redelivered : Bool = false,
) : RMQ::BrokerDelivery
  RMQ::BrokerDelivery.new(
    token,
    "tori_py.rpc",
    routing_key,
    Bytes[4, 5, 6],
    message_id: message_id.to_s,
    correlation_id: correlation_id.try(&.to_s),
    reply_to: reply_to.try(&.value),
    content_type: "application/json",
    expiration_ms: 5_000_i64,
    headers: headers,
    redelivered: redelivered,
  )
end

describe RMQ::Settings do
  it "validates bounded broker settings" do
    expect_raises(RMQ::ConfigurationError, "must not be empty") do
      RMQ::Settings.new("")
    end
    expect_raises(RMQ::ConfigurationError, "prefetch") do
      RMQ::Settings.new("amqp://localhost", prefetch: 0)
    end
    expect_raises(RMQ::ConfigurationError, "retry_delay") do
      RMQ::Settings.new("amqp://localhost", retry_delay: 0.seconds)
    end
  end

  it "loads broker settings from application configuration" do
    path = "/tmp/opal-rabbitmq-settings-#{Process.pid}.yml"
    File.write(path, <<-YAML)
      microservices:
        rabbitmq:
          url: amqps://opal:secret@rabbit.internal/vhost
          prefetch: 16
          work_pool: 4
          max_attempts: 5
          max_queue_length: 2500
          retry_delay_ms: 750
      YAML

    settings = RMQ::Settings.from_config(LF::ConfigService.new(path))
    settings.url.should eq("amqps://opal:secret@rabbit.internal/vhost")
    settings.prefetch.should eq(16)
    settings.work_pool.should eq(4)
    settings.max_attempts.should eq(5)
    settings.max_queue_length.should eq(2_500)
    settings.retry_delay.should eq(750.milliseconds)
  ensure
    File.delete(path) if path && File.exists?(path)
  end
end

describe RMQ::ServerTransport do
  it "declares deterministic bounded RPC and event topology" do
    session = RabbitFakeSession.new
    event_source = MS::ServiceIdentity.new("warehouse", "inventory", 1)
    event = MS::EventIdentity.new(event_source, "stock-changed", 1)
    subscription = MS::EventSubscription.new(
      event,
      MS::EventDispatchMode::ServicePool,
      "projector",
      destination: rabbit_service,
    )
    server = RMQ::ServerTransport.new(
      rabbit_service,
      rabbit_settings(max_queue_length: 73),
      session_factory: rabbit_factory(session),
    )

    server.prepare([rabbit_target.method], [subscription])
    server.start(->(_delivery : MS::EncodedDelivery) { MS::SettlementRecommendation::Ack })

    session.exchanges.should contain({"tori_py.rpc", "topic", true})
    session.exchanges.should contain({"tori_py.retry", "topic", true})
    session.exchanges.should contain({"tori_py.dead-letter", "topic", true})
    session.exchanges.should contain({"tori_py.events.warehouse.inventory.v1", "topic", true})

    rpc_queue = "tori_py.rpc.shop.catalog.v1"
    rpc_options = session.queues[rpc_queue]
    rpc_options.durable.should be_true
    rpc_options.dead_letter_exchange.should eq("tori_py.dead-letter")
    rpc_options.max_length.should eq(73)
    session.bindings.should contain({rpc_queue, "tori_py.rpc", "shop.catalog.v1.*"})

    retry_queue = "#{rpc_queue}.retry.find"
    retry_options = session.queues[retry_queue]
    retry_options.message_ttl.should eq(250.milliseconds)
    retry_options.dead_letter_exchange.should eq("tori_py.rpc")
    retry_options.dead_letter_routing_key.should eq(rabbit_target.routing_key)
    session.bindings.should contain({retry_queue, "tori_py.retry", retry_queue})

    event_queue = "tori_py.event.warehouse.inventory.v1.stock-changed.v1.service_pool.shop.catalog.v1.projector"
    session.queues[event_queue].durable.should be_true
    session.bindings.should contain({
      event_queue,
      "tori_py.events.warehouse.inventory.v1",
      "stock-changed.v1",
    })
    session.consumers.map(&.[2]).uniq.should eq([7_u16])
    session.consumers.map(&.[3]).uniq.should eq([2])
  ensure
    server.try(&.close)
  end

  it "declares ephemeral broadcasts as exclusive auto-delete queues" do
    session = RabbitFakeSession.new
    event = MS::EventIdentity.new(rabbit_service, "refreshed", 1)
    subscription = MS::EventSubscription.new(
      event,
      MS::EventDispatchMode::Broadcast,
      "live-view",
      destination: rabbit_service,
      instance_id: "node-a",
      reliable: false,
    )
    server = RMQ::ServerTransport.new(
      rabbit_service,
      rabbit_settings,
      session_factory: rabbit_factory(session),
    )

    server.prepare([] of String, [subscription])
    server.start(->(_delivery : MS::EncodedDelivery) { MS::SettlementRecommendation::Ack })

    queue = "tori_py.event.shop.catalog.v1.refreshed.v1.broadcast.shop.catalog.v1.live-view.node-a"
    options = session.queues[queue]
    options.durable.should be_false
    options.exclusive.should be_true
    options.auto_delete.should be_true
    session.queues.keys.none?(&.ends_with?(".dead")).should be_true
  ensure
    server.try(&.close)
  end

  it "maps broker metadata, strips retry headers, and manually acknowledges" do
    session = RabbitFakeSession.new
    now = Time.utc(2026, 1, 1, 12)
    seen = [] of MS::EncodedDelivery
    server = RMQ::ServerTransport.new(
      rabbit_service,
      rabbit_settings,
      session_factory: rabbit_factory(session),
      clock: -> { now },
    )
    server.prepare([rabbit_target.method], [] of MS::EventSubscription)
    server.start(->(delivery : MS::EncodedDelivery) {
      seen << delivery
      MS::SettlementRecommendation::Ack
    })
    headers = {
      RMQ::ATTEMPT_HEADER => JSON::Any.new(2_i64),
      "trace"             => JSON::Any.new("abc"),
    }

    session.deliver(
      "tori_py.rpc.shop.catalog.v1",
      rabbit_broker_delivery(headers: headers, redelivered: true),
    )

    delivery = seen.first
    delivery.attempt.should eq(2)
    delivery.redelivered.should be_true
    delivery.headers.should eq({"trace" => JSON::Any.new("abc")})
    delivery.expires_at.should eq(now + 5.seconds)
    session.acknowledgements.should eq([1_u64])
    server.inflight_count.should eq(0)
  ensure
    server.try(&.close)
  end

  it "publishes bounded retries before acknowledging the original delivery" do
    session = RabbitFakeSession.new
    server = RMQ::ServerTransport.new(
      rabbit_service,
      rabbit_settings(max_attempts: 3),
      session_factory: rabbit_factory(session),
    )
    server.prepare([rabbit_target.method], [] of MS::EventSubscription)
    server.start(->(_delivery : MS::EncodedDelivery) { MS::SettlementRecommendation::Retry })

    session.deliver(
      "tori_py.rpc.shop.catalog.v1",
      rabbit_broker_delivery(headers: {"trace" => JSON::Any.new("abc")}),
    )

    exchange, publication, persistent = session.publications.first
    exchange.should eq("tori_py.retry")
    publication.routing_key.should eq("tori_py.rpc.shop.catalog.v1.retry.find")
    publication.headers[RMQ::ATTEMPT_HEADER].as_i64.should eq(2)
    publication.headers["trace"].as_s.should eq("abc")
    persistent.should be_true
    session.acknowledgements.should eq([1_u64])
    session.rejections.should be_empty
  ensure
    server.try(&.close)
  end

  it "dead-letters after the configured maximum attempt" do
    session = RabbitFakeSession.new
    server = RMQ::ServerTransport.new(
      rabbit_service,
      rabbit_settings(max_attempts: 3),
      session_factory: rabbit_factory(session),
    )
    server.prepare([rabbit_target.method], [] of MS::EventSubscription)
    server.start(->(_delivery : MS::EncodedDelivery) { MS::SettlementRecommendation::Retry })

    session.deliver(
      "tori_py.rpc.shop.catalog.v1",
      rabbit_broker_delivery(
        token: 9_u64,
        headers: {RMQ::ATTEMPT_HEADER => JSON::Any.new(3_i64)},
      ),
    )

    session.publications.should be_empty
    session.acknowledgements.should be_empty
    session.rejections.should eq([{9_u64, false}])
  ensure
    server.try(&.close)
  end

  it "rejects malformed broker deliveries without invoking application code" do
    session = RabbitFakeSession.new
    invoked = false
    server = RMQ::ServerTransport.new(
      rabbit_service,
      rabbit_settings,
      session_factory: rabbit_factory(session),
    )
    server.prepare([rabbit_target.method], [] of MS::EventSubscription)
    server.start(->(_delivery : MS::EncodedDelivery) {
      invoked = true
      MS::SettlementRecommendation::Ack
    })
    malformed = RMQ::BrokerDelivery.new(
      11_u64,
      "tori_py.rpc",
      rabbit_target.routing_key,
      Bytes[1],
    )

    session.deliver("tori_py.rpc.shop.catalog.v1", malformed)

    invoked.should be_false
    session.rejections.should eq([{11_u64, false}])
  ensure
    server.try(&.close)
  end

  it "cancels consumers and drains only already delivered work" do
    session = RabbitFakeSession.new
    pending = [] of MS::EncodedDelivery
    server = RMQ::ServerTransport.new(
      rabbit_service,
      rabbit_settings,
      session_factory: rabbit_factory(session),
    )
    server.prepare([rabbit_target.method], [] of MS::EventSubscription)
    server.start(->(delivery : MS::EncodedDelivery) {
      pending << delivery
      MS::SettlementRecommendation::Unsettled
    })
    session.deliver("tori_py.rpc.shop.catalog.v1", rabbit_broker_delivery)

    server.stop_intake
    session.cancellations.size.should eq(1)
    server.drain(Time.instant + 1.millisecond).should be_false
    server.settle(pending.first, MS::SettlementRecommendation::Ack)
    server.drain(Time.instant + 1.second).should be_true
  ensure
    server.try(&.close)
  end
end

describe RMQ::ClientTransport do
  it "uses an exclusive bounded reply queue and confirmed RPC publications" do
    session = RabbitFakeSession.new
    client = RMQ::ClientTransport.new(
      rabbit_settings,
      session_factory: rabbit_factory(session),
      max_pending: 3,
      max_replies: 5,
    )
    client.start
    publication = rabbit_rpc_publication(client)

    receipt = client.publish_rpc(rabbit_target, publication)

    reply_options = session.queues[client.reply_to.value]
    reply_options.durable.should be_false
    reply_options.exclusive.should be_true
    reply_options.auto_delete.should be_true
    reply_options.max_length.should eq(5)
    exchange, recorded, persistent = session.publications.first
    exchange.should eq("tori_py.rpc")
    recorded.message_id.should eq(publication.message_id)
    persistent.should be_true
    receipt.routed.should be_true
    client.pending_count.should eq(1)
  ensure
    client.try(&.close)
  end

  it "validates RPC routes and maps broker nack and mandatory return" do
    session = RabbitFakeSession.new
    client = RMQ::ClientTransport.new(
      rabbit_settings,
      session_factory: rabbit_factory(session),
    )
    client.start
    mismatched = MS::Publication.new(
      UUID.random,
      "shop.catalog.v1.other",
      Bytes[1],
      mandatory: true,
      correlation_id: UUID.random,
      reply_to: client.reply_to,
    )
    expect_raises(MS::TransportRejectedError, "routing key") do
      client.publish_rpc(rabbit_target, mismatched)
    end

    session.enqueue_publish_result(false, true)
    expect_raises(MS::TransportRejectedError, "negatively acknowledged") do
      client.publish_rpc(rabbit_target, rabbit_rpc_publication(client))
    end

    session.enqueue_publish_result(true, false)
    expect_raises(MS::TransportUnroutableError, "mandatory publication") do
      client.publish_rpc(rabbit_target, rabbit_rpc_publication(client))
    end
    client.pending_count.should eq(0)
  ensure
    client.try(&.close)
  end

  it "correlates and acknowledges replies" do
    session = RabbitFakeSession.new
    client = RMQ::ClientTransport.new(
      rabbit_settings,
      session_factory: rabbit_factory(session),
    )
    client.start
    correlation_id = UUID.random
    publication = rabbit_rpc_publication(client, correlation_id)
    client.publish_rpc(rabbit_target, publication)
    reply = rabbit_broker_delivery(
      routing_key: client.reply_to.value,
      token: 41_u64,
      correlation_id: correlation_id,
      reply_to: nil,
    )

    session.deliver(client.reply_to.value, reply)
    received = client.next_reply.as(MS::EncodedDelivery)

    received.correlation_id.should eq(correlation_id)
    received.body.should eq(Bytes[4, 5, 6])
    session.acknowledgements.should eq([41_u64])
    client.pending_count.should eq(0)
  ensure
    client.try(&.close)
  end

  it "reports unknown reply correlations without requeueing them" do
    session = RabbitFakeSession.new
    client = RMQ::ClientTransport.new(
      rabbit_settings,
      session_factory: rabbit_factory(session),
    )
    client.start
    correlation_id = UUID.random
    session.deliver(
      client.reply_to.value,
      rabbit_broker_delivery(
        routing_key: client.reply_to.value,
        token: 51_u64,
        correlation_id: correlation_id,
        reply_to: nil,
      ),
    )

    failure = client.next_reply.as(MS::ReplyProtocolFailure)
    failure.correlation_id.should eq(correlation_id)
    session.acknowledgements.should eq([51_u64])
  ensure
    client.try(&.close)
  end

  it "reconnects to a fresh reply route without replaying accepted RPC" do
    first = RabbitFakeSession.new
    second = RabbitFakeSession.new
    sessions = Deque(RabbitFakeSession).new([first, second])
    factory = -> { sessions.shift.as(RMQ::Session) }
    client = RMQ::ClientTransport.new(rabbit_settings, session_factory: factory)
    client.start
    old_route = client.reply_to
    publication = rabbit_rpc_publication(client)
    client.publish_rpc(rabbit_target, publication)

    canceled = client.reconnect

    canceled.should eq([publication.correlation_id.not_nil!])
    first.closed?.should be_true
    second.publications.should be_empty
    client.reply_to.should_not eq(old_route)
    client.generation.should eq(2)
    client.pending_count.should eq(0)
  ensure
    client.try(&.close)
  end

  it "surfaces a disconnected reply session instead of returning no reply" do
    session = RabbitFakeSession.new
    client = RMQ::ClientTransport.new(
      rabbit_settings,
      session_factory: rabbit_factory(session),
    )
    client.start
    session.disconnect

    expect_raises(MS::TransportUnavailableError, "disconnected") do
      client.next_reply?
    end
  ensure
    client.try(&.close)
  end

  it "treats publish exceptions as indeterminate outcomes" do
    session = RabbitFakeSession.new
    client = RMQ::ClientTransport.new(
      rabbit_settings,
      session_factory: rabbit_factory(session),
    )
    client.start
    session.fail_publish(IO::Error.new("socket closed"))

    expect_raises(MS::TransportIndeterminateError, "outcome is unknown") do
      client.publish_rpc(rabbit_target, rabbit_rpc_publication(client))
    end
    client.pending_count.should eq(0)
  ensure
    client.try(&.close)
  end
end
