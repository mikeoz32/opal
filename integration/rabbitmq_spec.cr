require "../spec/spec_helper"
require "../src/opal/microservices/rabbitmq"

private alias MS = LF::Microservices
private alias RMQ = LF::Microservices::RabbitMQ

private RABBITMQ_TEST_URL = ENV["OPAL_RABBITMQ_TEST_URL"]?

private def rabbitmq_integration_profile(token : String) : MS::ProtocolProfile
  MS::ProtocolProfile.new(
    topology: MS::TopologyConfig.new(
      rpc_exchange: "opal_it.#{token}.rpc",
      rpc_queue_prefix: "opal_it.#{token}.rpc_queue",
      event_exchange_prefix: "opal_it.#{token}.events",
      event_queue_prefix: "opal_it.#{token}.event_queue",
      reply_queue_prefix: "opal_it.#{token}.reply",
      dead_letter_exchange: "opal_it.#{token}.dead",
      retry_exchange_prefix: "opal_it.#{token}.retry",
    ),
  )
end

private def rabbitmq_integration_token(label : String) : String
  "it#{Process.pid}#{Random::Secure.hex(4)}#{label}"
end

private def rabbitmq_integration_settings(
  max_queue_length : Int32 = 100,
) : RMQ::Settings
  RMQ::Settings.new(
    RABBITMQ_TEST_URL.not_nil!,
    prefetch: 8,
    work_pool: 2,
    max_attempts: 2,
    max_queue_length: max_queue_length,
    retry_delay: 50.milliseconds,
  )
end

private def wait_for_rabbitmq(
  timeout : Time::Span = 5.seconds,
  &condition : -> Bool
) : Nil
  deadline = Time.instant + timeout
  until condition.call
    raise "RabbitMQ integration condition timed out" if Time.instant >= deadline
    sleep 5.milliseconds
  end
end

if RABBITMQ_TEST_URL
  describe "RabbitMQ 4 transport integration" do
    it "round-trips a confirmed RPC reply and settles the request" do
      profile = rabbitmq_integration_profile(rabbitmq_integration_token("rpc"))
      service = MS::ServiceIdentity.new("shop", "catalog", 1)
      target = MS::RPCTarget.new(service, "find", 1)
      settings = rabbitmq_integration_settings
      server : RMQ::ServerTransport? = nil
      active_server = RMQ::ServerTransport.new(service, settings, profile)
      server = active_server
      active_server.prepare([target.method], [] of MS::EventSubscription)
      active_server.start(->(delivery : MS::EncodedDelivery) {
        active_server.publish_reply(MS::Publication.new(
          UUID.random,
          delivery.reply_to.not_nil!.value,
          Bytes[9, 8, 7],
          mandatory: true,
          correlation_id: delivery.correlation_id,
        ))
        MS::SettlementRecommendation::Ack
      })
      client = RMQ::ClientTransport.new(settings, profile)
      client.start
      correlation_id = UUID.random
      publication = MS::Publication.new(
        UUID.random,
        target.routing_key,
        Bytes[1, 2, 3],
        mandatory: true,
        correlation_id: correlation_id,
        reply_to: client.reply_to,
        expires_at: Time.utc + 5.seconds,
      )

      client.publish_rpc(target, publication).routed.should be_true
      reply = nil.as(MS::EncodedDelivery | MS::ReplyProtocolFailure | Nil)
      wait_for_rabbitmq do
        reply = client.next_reply?
        !reply.nil?
      end

      delivery = reply.as(MS::EncodedDelivery)
      delivery.body.should eq(Bytes[9, 8, 7])
      delivery.correlation_id.should eq(correlation_id)
      wait_for_rabbitmq { active_server.inflight_count == 0 }
    ensure
      client.try(&.close)
      server.try(&.close)
    end

    it "delays and redelivers retry settlements with a bounded attempt" do
      profile = rabbitmq_integration_profile(rabbitmq_integration_token("retry"))
      service = MS::ServiceIdentity.new("shop", "catalog", 1)
      target = MS::RPCTarget.new(service, "find", 1)
      settings = rabbitmq_integration_settings
      attempts = [] of Int32
      lock = Mutex.new
      server = RMQ::ServerTransport.new(service, settings, profile)
      server.prepare([target.method], [] of MS::EventSubscription)
      server.start(->(delivery : MS::EncodedDelivery) {
        lock.synchronize { attempts << delivery.attempt }
        delivery.attempt == 1 ? MS::SettlementRecommendation::Retry : MS::SettlementRecommendation::Ack
      })
      client = RMQ::ClientTransport.new(settings, profile)
      client.start
      publication = MS::Publication.new(
        UUID.random,
        target.routing_key,
        Bytes[1],
        mandatory: true,
        correlation_id: UUID.random,
        reply_to: client.reply_to,
        expires_at: Time.utc + 5.seconds,
      )

      client.publish_rpc(target, publication).routed.should be_true
      wait_for_rabbitmq { lock.synchronize { attempts.size == 2 } }

      lock.synchronize { attempts.dup }.should eq([1, 2])
      wait_for_rabbitmq { server.inflight_count == 0 }
    ensure
      client.try(&.close)
      server.try(&.close)
    end

    it "returns mandatory RPC publications when no service queue is bound" do
      profile = rabbitmq_integration_profile(rabbitmq_integration_token("unroutable"))
      service = MS::ServiceIdentity.new("shop", "catalog", 1)
      target = MS::RPCTarget.new(service, "find", 1)
      client = RMQ::ClientTransport.new(rabbitmq_integration_settings, profile)
      client.start
      publication = MS::Publication.new(
        UUID.random,
        target.routing_key,
        Bytes[1],
        mandatory: true,
        correlation_id: UUID.random,
        reply_to: client.reply_to,
      )

      expect_raises(MS::TransportUnroutableError) do
        client.publish_rpc(target, publication)
      end
      client.pending_count.should eq(0)
    ensure
      client.try(&.close)
    end

    it "surfaces inequivalent durable queue declarations" do
      profile = rabbitmq_integration_profile(rabbitmq_integration_token("conflict"))
      service = MS::ServiceIdentity.new("shop", "catalog", 1)
      target = MS::RPCTarget.new(service, "find", 1)
      first = RMQ::ServerTransport.new(
        service,
        rabbitmq_integration_settings(max_queue_length: 10),
        profile,
      )
      first.prepare([target.method], [] of MS::EventSubscription)
      first.start(->(_delivery : MS::EncodedDelivery) { MS::SettlementRecommendation::Ack })
      first.close

      second = RMQ::ServerTransport.new(
        service,
        rabbitmq_integration_settings(max_queue_length: 11),
        profile,
      )
      second.prepare([target.method], [] of MS::EventSubscription)

      expect_raises(MS::TransportUnavailableError) do
        second.start(->(_delivery : MS::EncodedDelivery) { MS::SettlementRecommendation::Ack })
      end
    ensure
      second.try(&.close)
      first.try(&.close)
    end

    it "returns replies whose exclusive client route was deleted" do
      profile = rabbitmq_integration_profile(rabbitmq_integration_token("deletedreply"))
      service = MS::ServiceIdentity.new("shop", "catalog", 1)
      settings = rabbitmq_integration_settings
      server = RMQ::ServerTransport.new(service, settings, profile)
      server.prepare([] of String, [] of MS::EventSubscription)
      server.start(->(_delivery : MS::EncodedDelivery) { MS::SettlementRecommendation::Ack })
      client = RMQ::ClientTransport.new(settings, profile)
      client.start
      deleted_route = client.reply_to
      client.close

      expect_raises(MS::TransportUnroutableError) do
        server.publish_reply(MS::Publication.new(
          UUID.random,
          deleted_route.value,
          Bytes[1],
          mandatory: true,
          correlation_id: UUID.random,
        ))
      end
    ensure
      client.try(&.close)
      server.try(&.close)
    end
  end
else
  describe "RabbitMQ 4 transport integration" do
    pending "requires OPAL_RABBITMQ_TEST_URL" do
    end
  end
end
