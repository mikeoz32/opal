# Shared behavioral contract for every LF::Microservices transport adapter.
#
# A concrete harness passed to `define` must expose the methods used below:
# `service`, `target`, `event`, `rpc_publication`, `event_publication`,
# `start_server`, `start_client`, `dispatch_one`, `pending_count`,
# `inflight_count`, `reconnect`, and `close`. Keeping broker-specific pumping
# and inspection behind those methods lets a RabbitMQ harness wait for
# asynchronous delivery while the in-memory harness advances deterministically.
module MicroservicesTransportConformance
  macro define(description, harness_type)
    describe {{description}} do
      it "follows the server and client lifecycle contract" do
        harness = {{harness_type}}.new
        begin
          server = harness.start_server(
            ->(delivery : LF::Microservices::EncodedDelivery) {
              LF::Microservices::SettlementRecommendation::Ack
            },
          )
          client = harness.start_client

          server.status.running?.should be_true
          client.status.running?.should be_true
          client.generation.should eq(1)

          server.stop_intake
          server.status.quiescing?.should be_true
          server.close
          server.status.closed?.should be_true

          client.close
          client.status.closed?.should be_true
        ensure
          harness.close
        end
      end

      it "routes RPC requests across competing service consumers" do
        harness = {{harness_type}}.new
        begin
          seen = [] of UUID
          handler = ->(delivery : LF::Microservices::EncodedDelivery) {
            seen << delivery.message_id
            LF::Microservices::SettlementRecommendation::Ack
          }
          first = harness.start_server(handler)
          second = harness.start_server(handler)
          client = harness.start_client

          publications = (1..4).map do |number|
            publication = harness.rpc_publication(client, number)
            client.publish_rpc(harness.target, publication).routed.should be_true
            publication
          end

          harness.pending_count(first).should eq(2)
          harness.pending_count(second).should eq(2)
          harness.dispatch_one(first)
          harness.dispatch_one(first)
          harness.dispatch_one(second)
          harness.dispatch_one(second)

          seen.sort_by(&.to_s).should eq(publications.map(&.message_id).sort_by(&.to_s))
        ensure
          harness.close
        end
      end

      it "distinguishes mandatory unroutable publication from destination capacity" do
        harness = {{harness_type}}.new
        begin
          client = harness.start_client
          expect_raises(LF::Microservices::TransportUnroutableError) do
            client.publish_rpc(harness.target, harness.rpc_publication(client, 1))
          end

          server = harness.start_server(
            ->(delivery : LF::Microservices::EncodedDelivery) {
              LF::Microservices::SettlementRecommendation::Ack
            },
            max_queue_size: 1,
          )
          client.publish_rpc(harness.target, harness.rpc_publication(client, 2))
          expect_raises(LF::Microservices::TransportCapacityError) do
            client.publish_rpc(harness.target, harness.rpc_publication(client, 3))
          end
          harness.pending_count(server).should eq(1)
          client.pending_count.should eq(1)
        ensure
          harness.close
        end
      end

      it "redelivers retry settlements as a later attempt" do
        harness = {{harness_type}}.new
        begin
          attempts = [] of Tuple(Int32, Bool)
          server = harness.start_server(
            ->(delivery : LF::Microservices::EncodedDelivery) {
              attempts << {delivery.attempt, delivery.redelivered}
              delivery.attempt == 1 ?
                LF::Microservices::SettlementRecommendation::Retry :
                LF::Microservices::SettlementRecommendation::Ack
            },
          )
          client = harness.start_client
          client.publish_rpc(harness.target, harness.rpc_publication(client))

          harness.dispatch_one(server)
          harness.dispatch_one(server)

          attempts.should eq([{1, false}, {2, true}])
          harness.pending_count(server).should eq(0)
          harness.inflight_count(server).should eq(0)
        ensure
          harness.close
        end
      end

      it "rejects duplicate settlement" do
        harness = {{harness_type}}.new
        begin
          server = harness.start_server(
            ->(delivery : LF::Microservices::EncodedDelivery) {
              LF::Microservices::SettlementRecommendation::Unsettled
            },
          )
          client = harness.start_client
          client.publish_rpc(harness.target, harness.rpc_publication(client))
          delivery = harness.dispatch_one(server).not_nil!

          server.settle(delivery, LF::Microservices::SettlementRecommendation::Ack)
          expect_raises(LF::Microservices::DuplicateSettlementError) do
            server.settle(delivery, LF::Microservices::SettlementRecommendation::Ack)
          end
        ensure
          harness.close
        end
      end

      it "correlates confirmed replies with pending RPC requests" do
        harness = {{harness_type}}.new
        begin
          server = uninitialized typeof(harness.start_server(
            ->(delivery : LF::Microservices::EncodedDelivery) {
              LF::Microservices::SettlementRecommendation::Ack
            },
          ))
          server = harness.start_server(
            ->(delivery : LF::Microservices::EncodedDelivery) {
              server.publish_reply(LF::Microservices::Publication.new(
                UUID.random,
                delivery.reply_to.not_nil!.value,
                Bytes[9],
                mandatory: true,
                correlation_id: delivery.correlation_id,
              ))
              LF::Microservices::SettlementRecommendation::Ack
            },
          )
          client = harness.start_client
          publication = harness.rpc_publication(client)
          client.publish_rpc(harness.target, publication)

          harness.dispatch_one(server)
          reply = client.next_reply.as(LF::Microservices::EncodedDelivery)

          reply.body.should eq(Bytes[9])
          reply.correlation_id.should eq(publication.correlation_id)
          client.pending_count.should eq(0)
        ensure
          harness.close
        end
      end

      it "competes service-pool events and copies broadcast events" do
        harness = {{harness_type}}.new
        begin
          handler = ->(delivery : LF::Microservices::EncodedDelivery) {
            LF::Microservices::SettlementRecommendation::Ack
          }
          pool = LF::Microservices::EventSubscription.new(
            harness.event,
            LF::Microservices::EventDispatchMode::ServicePool,
            "projector",
            destination: harness.service,
          )
          first = harness.start_server(handler, subscriptions: [pool])
          second = harness.start_server(handler, subscriptions: [pool])
          client = harness.start_client(receive_replies: false)

          client.publish_event(harness.event, harness.event_publication(1))
          client.publish_event(harness.event, harness.event_publication(2))
          harness.pending_count(first).should eq(1)
          harness.pending_count(second).should eq(1)

          first.close
          second.close
          first_broadcast = LF::Microservices::EventSubscription.new(
            harness.event,
            LF::Microservices::EventDispatchMode::Broadcast,
            "live-stock",
            destination: harness.service,
          )
          second_broadcast = LF::Microservices::EventSubscription.new(
            harness.event,
            LF::Microservices::EventDispatchMode::Broadcast,
            "live-stock",
            destination: harness.service,
          )
          first = harness.start_server(handler, subscriptions: [first_broadcast])
          second = harness.start_server(handler, subscriptions: [second_broadcast])

          client.publish_event(harness.event, harness.event_publication(3))
          harness.pending_count(first).should eq(1)
          harness.pending_count(second).should eq(1)
        ensure
          harness.close
        end
      end

      it "stops intake while draining already accepted work" do
        harness = {{harness_type}}.new
        begin
          server = harness.start_server(
            ->(delivery : LF::Microservices::EncodedDelivery) {
              LF::Microservices::SettlementRecommendation::Ack
            },
          )
          client = harness.start_client
          client.publish_rpc(harness.target, harness.rpc_publication(client, 1))

          server.stop_intake
          expect_raises(LF::Microservices::TransportUnroutableError) do
            client.publish_rpc(harness.target, harness.rpc_publication(client, 2))
          end
          server.drain(Time.instant + 1.second).should be_true
          harness.pending_count(server).should eq(0)
        ensure
          harness.close
        end
      end

      it "reconnects with a new reply generation and never replays accepted RPC" do
        harness = {{harness_type}}.new
        begin
          server = harness.start_server(
            ->(delivery : LF::Microservices::EncodedDelivery) {
              LF::Microservices::SettlementRecommendation::Ack
            },
          )
          client = harness.start_client
          original_route = client.reply_to
          publication = harness.rpc_publication(client)
          client.publish_rpc(harness.target, publication)

          canceled = client.reconnect

          canceled.should eq([publication.correlation_id.not_nil!])
          client.pending_count.should eq(0)
          client.generation.should eq(2)
          client.reply_to.should_not eq(original_route)
          harness.pending_count(server).should eq(1)
        ensure
          harness.close
        end
      end
    end
  end
end
