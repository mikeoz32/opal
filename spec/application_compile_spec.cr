require "./spec_helper"

private def compile_fixture(path : String) : NamedTuple(status: Process::Status, output: String, error: String)
  output = IO::Memory.new
  error = IO::Memory.new
  cache_dir = ENV.fetch("CRYSTAL_CACHE_DIR", "/tmp/opal-crystal-cache")
  Dir.mkdir_p(cache_dir)

  status = Process.run(
    "crystal",
    ["build", "--no-codegen", path],
    env: {"CRYSTAL_CACHE_DIR" => cache_dir},
    output: output,
    error: error
  )

  {status: status, output: output.to_s, error: error.to_s}
end

describe "application compiler fixtures" do
  it "keeps standalone DI executables valid without an application marker" do
    fixture = File.expand_path("fixtures/application/standalone_di.cr", __DIR__)
    result = compile_fixture(fixture)

    result[:status].success?.should be_true
    result[:error].should eq("")
  end

  it "rejects multiple application markers" do
    fixture = File.expand_path("fixtures/application/multiple_applications.cr", __DIR__)
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain("Only one @[LF::Application] is allowed per executable")
  end

  it "rejects application classes that require constructor arguments" do
    fixture = File.expand_path("fixtures/application/application_requires_arguments.cr", __DIR__)
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain("wrong number of arguments for 'InvalidApp.new'")
  end

  it "rejects configuration classes that require constructor arguments" do
    fixture = File.expand_path("fixtures/application/configuration_requires_arguments.cr", __DIR__)
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain("wrong number of arguments for 'InvalidConfiguration.new'")
  end

  it "rejects non-integer configuration priorities with an actionable error" do
    fixture = File.expand_path("fixtures/application/invalid_configuration_priority.cr", __DIR__)
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain("Invalid application configuration priority for InvalidPriorityConfiguration")
  end

  it "does not expose the runtime container" do
    fixture = File.expand_path("fixtures/application/runtime_context_access.cr", __DIR__)
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain("undefined method 'context' for LF::ApplicationRuntime")
  end
end
