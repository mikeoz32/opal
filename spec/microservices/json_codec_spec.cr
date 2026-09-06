require "../spec_helper"
require "../../src/opal/microservices"

private alias MS = LF::Microservices

private def wire_fixture(name : String) : String
  File.read(File.join(__DIR__, "../fixtures/microservices/wire-v1", name)).chomp
end

private def fixture_service : MS::ServiceIdentity
  MS::ServiceIdentity.new("shop", "catalog", 1)
end

private def fixture_request : MS::RPCRequestEnvelope
  MS::RPCRequestEnvelope.new(
    message_id: UUID.new("11111111-1111-4111-8111-111111111111"),
    service: fixture_service,
    method: "find",
    schema_version: 1,
    created_at: Time.utc(2026, 1, 1, 12),
    deadline_at: Time.utc(2026, 1, 1, 12, 0, 5),
    correlation_id: UUID.new("22222222-2222-4222-8222-222222222222"),
    causation_id: UUID.new("33333333-3333-4333-8333-333333333333"),
    reply_to: MS::ReplyRoute.new("reply.0123456789abcdef0123456789abcdef"),
    headers: JSON.parse(%({"trace":{"sampled":true},"tenant":"acme"})).as_h,
    payload: JSON.parse(%({"sku":"opal-1","quantity":2})),
  )
end

describe MS::JSONCodec do
  codec = MS::JSONCodec.new

  it "matches the request bytes emitted by tori-py v1" do
    encoded = String.new(codec.encode_request(fixture_request))
    encoded.should eq(wire_fixture("rpc-request.json"))

    decoded = codec.decode_request(encoded)
    decoded.service.should eq(fixture_service)
    decoded.method.should eq("find")
    decoded.payload["quantity"].as_i.should eq(2)
    decoded.headers["trace"]["sampled"].as_bool.should be_true
  end

  it "matches successful and failed response bytes emitted by tori-py v1" do
    correlation_id = UUID.new("22222222-2222-4222-8222-222222222222")
    success = MS::RPCResponseEnvelope.success(
      message_id: UUID.new("44444444-4444-4444-8444-444444444444"),
      correlation_id: correlation_id,
      completed_at: Time.utc(2026, 1, 1, 12, nanosecond: 123_456_000),
      result: JSON.parse(%({"stock":12,"available":true})),
    )
    error = MS::RemoteRPCErrorData.new(
      "not_found",
      "Product was not found.",
      details: JSON.parse(%({"sku":"opal-1"})).as_h,
    )
    failure = MS::RPCResponseEnvelope.failure(
      message_id: UUID.new("55555555-5555-4555-8555-555555555555"),
      correlation_id: correlation_id,
      completed_at: Time.utc(2026, 1, 1, 12, 0, 1),
      error: error,
    )

    String.new(codec.encode_response(success)).should eq(wire_fixture("rpc-success.json"))
    String.new(codec.encode_response(failure)).should eq(wire_fixture("rpc-error.json"))
    codec.decode_response(wire_fixture("rpc-success.json")).success?.should be_true
    decoded_error = codec.decode_response(wire_fixture("rpc-error.json"))
    decoded_error.success?.should be_false
    decoded_error.error.not_nil!.code.should eq("not_found")
  end

  it "preserves a successful JSON null independently from an error" do
    response = MS::RPCResponseEnvelope.success(
      UUID.new("44444444-4444-4444-8444-444444444444"),
      UUID.new("22222222-2222-4222-8222-222222222222"),
      Time.utc(2026, 1, 1, 12),
    )

    decoded = codec.decode_response(codec.encode_response(response))
    decoded.success?.should be_true
    decoded.result.not_nil!.raw.should be_nil
    decoded.error.should be_nil
  end

  it "defensively copies nested envelope values" do
    headers = JSON.parse(%({"trace":{"sampled":true}})).as_h
    payload = JSON.parse(%({"items":[{"sku":"opal-1"}]}))
    request = MS::RPCRequestEnvelope.new(
      message_id: UUID.random,
      service: fixture_service,
      method: "find",
      schema_version: 1,
      created_at: Time.utc(2026, 1, 1, 12),
      deadline_at: Time.utc(2026, 1, 1, 12, 0, 5),
      correlation_id: UUID.random,
      reply_to: MS::ReplyRoute.new("reply.0123456789abcdef0123456789abcdef"),
      headers: headers,
      payload: payload,
    )

    headers["trace"].as_h["sampled"] = JSON::Any.new(false)
    payload["items"].as_a.first.as_h["sku"] = JSON::Any.new("changed")
    exposed_headers = request.headers
    exposed_headers["trace"].as_h["sampled"] = JSON::Any.new(false)

    request.headers["trace"]["sampled"].as_bool.should be_true
    request.payload["items"][0]["sku"].as_s.should eq("opal-1")
  end

  it "matches the event bytes emitted by tori-py v1" do
    event = MS::EventEnvelope.new(
      message_id: UUID.new("66666666-6666-4666-8666-666666666666"),
      source: fixture_service,
      event: "stock-changed",
      schema_version: 2,
      occurred_at: Time.utc(2026, 1, 1, 12),
      correlation_id: UUID.new("22222222-2222-4222-8222-222222222222"),
      causation_id: UUID.new("11111111-1111-4111-8111-111111111111"),
      headers: JSON.parse(%({"tenant":"acme"})).as_h,
      payload: JSON.parse(%({"stock":12,"available":true,"sku":"opal-1"})),
    )

    String.new(codec.encode_event(event)).should eq(wire_fixture("event.json"))
    decoded = codec.decode_event(wire_fixture("event.json"))
    decoded.event.should eq("stock-changed")
    decoded.schema_version.should eq(2)
  end

  it "rejects duplicate, missing, unknown, and non-finite JSON values" do
    expect_raises(MS::WireDecodingError, "duplicate JSON object member") do
      codec.decode_request(%({"kind":"rpc_request","kind":"rpc_request"}))
    end
    expect_raises(MS::WireDecodingError, "missing fields") do
      codec.decode_request(%({"kind":"rpc_request"}))
    end
    expect_raises(MS::WireDecodingError, "unknown fields") do
      codec.decode_request(wire_fixture("rpc-request.json").sub(
        ",\"payload\":",
        ",\"legacy\":true,\"payload\":"
      ))
    end
    expect_raises(MS::WireDecodingError) do
      codec.decode_request(%({"payload":1e999}))
    end
  end

  it "enforces envelope, header, collection, and nesting limits" do
    expect_raises(MS::WireLimitError, "wire envelope") do
      MS::JSONCodec.new(MS::MessageLimits.new(max_envelope_bytes: 8))
        .decode_request(%({"payload":"too large"}))
    end
    expect_raises(MS::WireLimitError, "headers") do
      MS::JSONCodec.new(MS::MessageLimits.new(max_header_bytes: 8))
        .decode_request(wire_fixture("rpc-request.json"))
    end
    expect_raises(MS::WireLimitError, "collection") do
      MS::JSONCodec.new(MS::MessageLimits.new(max_collection_items: 1))
        .encode_request(fixture_request)
    end
    expect_raises(MS::WireLimitError, "nesting") do
      MS::JSONCodec.new(MS::MessageLimits.new(max_nesting_depth: 1))
        .encode_request(fixture_request)
    end
  end

  it "requires canonical UUIDs, UTC timestamps, and future deadlines" do
    uppercase_uuid = wire_fixture("rpc-request.json").sub(
      "11111111-1111-4111-8111-111111111111",
      "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    )
    expect_raises(MS::WireDecodingError, "canonical UUID") do
      codec.decode_request(uppercase_uuid)
    end

    non_utc = wire_fixture("rpc-request.json").sub(
      "2026-01-01T12:00:00Z",
      "2026-01-01T14:00:00+02:00"
    )
    expect_raises(MS::WireDecodingError, "UTC") do
      codec.decode_request(non_utc)
    end

    expired_shape = wire_fixture("rpc-request.json").sub(
      "2026-01-01T12:00:05Z",
      "2026-01-01T12:00:00Z"
    )
    expect_raises(MS::WireDecodingError, "deadline_at") do
      codec.decode_request(expired_shape)
    end
  end
end
