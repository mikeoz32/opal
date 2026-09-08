require "./spec_helper"

private def compile_crabbit_streams_fixture(
  name : String,
) : NamedTuple(status: Process::Status, output: String, error: String)
  output = IO::Memory.new
  error = IO::Memory.new
  cache_dir = ENV.fetch("CRYSTAL_CACHE_DIR", "/tmp/opal-crabbit-streams-compile-cache")
  Dir.mkdir_p(cache_dir)
  fixture = File.expand_path("fixtures/microservices/#{name}.cr", __DIR__)
  status = Process.run(
    "crystal",
    ["build", "--no-codegen", fixture],
    env: {
      "CRYSTAL_CACHE_DIR" => cache_dir,
      "LIBRARY_PATH"      => ENV.fetch("LIBRARY_PATH", "/tmp"),
    },
    output: output,
    error: error,
  )
  {status: status, output: output.to_s, error: error.to_s}
end

describe "Crabbit Streams compiler" do
  it "compiles typed publishers, handlers, topology, and autoconfiguration" do
    result = compile_crabbit_streams_fixture("crabbit_streams_application")

    result[:status].success?.should be_true
    result[:error].should eq("")
  end

  {
    "crabbit_streams_event_without_json" => "must include JSON::Serializable",
    "crabbit_streams_wrong_signature"    => "#handle must accept event and LF::Microservices::StreamContext",
    "crabbit_streams_duplicate_route"    => "Duplicate stream handler route",
    "crabbit_streams_invalid_topology"   => "must include LF::Microservices::StreamTopology",
  }.each do |fixture, message|
    it "rejects #{fixture}" do
      result = compile_crabbit_streams_fixture(fixture)

      result[:status].success?.should be_false
      result[:error].should contain(message)
    end
  end
end
