require "../spec_helper"

private def compile_message_fixture(name : String)
  output = IO::Memory.new
  error = IO::Memory.new
  cache_dir = ENV.fetch("CRYSTAL_CACHE_DIR", "/tmp/opal-microservices-compile-cache")
  Dir.mkdir_p(cache_dir)
  path = File.join(__DIR__, "../fixtures/microservices", name)
  status = Process.run(
    "crystal",
    ["build", "--no-codegen", path],
    env: {"CRYSTAL_CACHE_DIR" => cache_dir},
    output: output,
    error: error,
  )
  {status: status, output: output.to_s, error: error.to_s}
end

describe "message handler compilation" do
  it "rejects duplicate RPC aliases across the explicit controller set" do
    result = compile_message_fixture("handlers_duplicate_rpc.cr")

    result[:status].success?.should be_false
    result[:error].should contain("Duplicate RPC method \"find\"")
  end

  it "rejects transport-incompatible policy types" do
    result = compile_message_fixture("handlers_invalid_policy.cr")

    result[:status].success?.should be_false
    result[:error].should contain("expected LF::Microservices::Guard")
  end

  it "requires explicit JSON DTO payloads" do
    result = compile_message_fixture("handlers_invalid_payload.cr")

    result[:status].success?.should be_false
    result[:error].should contain("must include JSON::Serializable")
  end
end
