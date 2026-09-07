require "./spec_helper"

private def compile_microservices_autoconfig_fixture(
  name : String,
) : NamedTuple(status: Process::Status, output: String, error: String)
  output = IO::Memory.new
  error = IO::Memory.new
  cache_dir = ENV.fetch("CRYSTAL_CACHE_DIR", "/tmp/opal-microservices-autoconfig-cache")
  Dir.mkdir_p(cache_dir)
  fixture = File.expand_path("fixtures/microservices/#{name}.cr", __DIR__)
  status = Process.run(
    "crystal",
    ["build", "--no-codegen", fixture],
    env: {"CRYSTAL_CACHE_DIR" => cache_dir},
    output: output,
    error: error,
  )
  {status: status, output: output.to_s, error: error.to_s}
end

private def run_microservices_autoconfig_fixture(
  name : String,
) : NamedTuple(status: Process::Status, output: String, error: String)
  output = IO::Memory.new
  error = IO::Memory.new
  cache_dir = ENV.fetch("CRYSTAL_CACHE_DIR", "/tmp/opal-microservices-autoconfig-cache")
  Dir.mkdir_p(cache_dir)
  fixture = File.expand_path("fixtures/microservices/#{name}.cr", __DIR__)
  status = Process.run(
    "crystal",
    ["run", fixture, "--no-color"],
    env: {"CRYSTAL_CACHE_DIR" => cache_dir},
    output: output,
    error: error,
  )
  {status: status, output: output.to_s, error: error.to_s}
end

describe "microservices autoconfiguration compiler" do
  it "generates bootstrap and process runners for a valid application" do
    result = compile_microservices_autoconfig_fixture("autoconfig_application")

    result[:status].success?.should be_true
    result[:error].should eq("")
  end

  it "assembles server and injectable clients with deterministic shutdown" do
    result = run_microservices_autoconfig_fixture("autoconfig_runtime")

    result[:status].success?.should be_true
    result[:output].should contain("runtime ok")
    result[:error].should eq("")
  end

  it "supports an outbound-only gateway without a fake local identity" do
    result = compile_microservices_autoconfig_fixture("autoconfig_client_only")

    result[:status].success?.should be_true
    result[:error].should eq("")
  end

  it "requires the marker to belong to an Application" do
    result = compile_microservices_autoconfig_fixture("autoconfig_without_application")

    result[:status].success?.should be_false
    result[:error].should contain(
      "@[LF::AutoConfig::Microservices] requires @[LF::Application] on InvalidMicroservicesOwner",
    )
  end

  it "rejects client types that do not include TypedServiceClient" do
    result = compile_microservices_autoconfig_fixture("autoconfig_invalid_client")

    result[:status].success?.should be_false
    result[:error].should contain("expected LF::Microservices::TypedServiceClient")
  end

  it "rejects an application with neither controllers nor clients" do
    result = compile_microservices_autoconfig_fixture("autoconfig_empty")

    result[:status].success?.should be_false
    result[:error].should contain("requires controllers or clients")
  end
end
