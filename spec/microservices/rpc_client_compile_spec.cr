require "../spec_helper"

private def compile_client_fixture(name : String)
  output = IO::Memory.new
  error = IO::Memory.new
  cache_dir = ENV.fetch("CRYSTAL_CACHE_DIR", "/tmp/opal-microservices-client-compile-cache")
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

describe "typed RPC client compilation" do
  it "rejects duplicate local RPC methods" do
    result = compile_client_fixture("client_duplicate_rpc.cr")

    result[:status].success?.should be_false
    result[:error].should contain("Duplicate typed RPC method find")
  end

  it "requires JSON-serializable request DTOs" do
    result = compile_client_fixture("client_invalid_request.cr")

    result[:status].success?.should be_false
    result[:error].should contain("PlainClientRequest must include JSON::Serializable")
  end

  it "requires JSON-serializable or Nil response DTOs" do
    result = compile_client_fixture("client_invalid_response.cr")

    result[:status].success?.should be_false
    result[:error].should contain("PlainClientResponse must include JSON::Serializable or be Nil")
  end
end
