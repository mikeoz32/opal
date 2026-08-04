require "./spec_helper"

private def run_autoconfiguration_fixture(path : String)
  output = IO::Memory.new
  error = IO::Memory.new
  cache_dir = ENV.fetch("CRYSTAL_CACHE_DIR", "/tmp/opal-crystal-cache")
  Dir.mkdir_p(cache_dir)

  status = Process.run(
    "crystal",
    ["run", "--no-debug", path],
    env: {"CRYSTAL_CACHE_DIR" => cache_dir},
    output: output,
    error: error
  )

  {status: status, output: output.to_s, error: error.to_s}
end

describe "conditional application autoconfiguration" do
  it "installs enabled extensions by priority and name, then stops in reverse" do
    fixture = File.expand_path(
      "fixtures/application/autoconfiguration_order.cr",
      __DIR__
    )

    result = run_autoconfiguration_fixture(fixture)

    result[:status].success?.should be_true
    result[:error].should eq("")
  end

  it "does not install an extension when its marker is absent" do
    fixture = File.expand_path(
      "fixtures/application/autoconfiguration_without_marker.cr",
      __DIR__
    )

    result = run_autoconfiguration_fixture(fixture)

    result[:status].success?.should be_true
    result[:error].should eq("")
  end

  it "stops installed extensions when a later constructor fails" do
    fixture = File.expand_path(
      "fixtures/application/autoconfiguration_constructor_failure.cr",
      __DIR__
    )

    result = run_autoconfiguration_fixture(fixture)

    result[:status].success?.should be_true
    result[:error].should eq("")
  end

  it "preserves configure failure after reverse extension and DI cleanup" do
    fixture = File.expand_path(
      "fixtures/application/autoconfiguration_configure_failure.cr",
      __DIR__
    )

    result = run_autoconfiguration_fixture(fixture)

    result[:status].success?.should be_true
    result[:error].should eq("")
  end

  it "reports configure and cleanup failures together" do
    fixture = File.expand_path(
      "fixtures/application/autoconfiguration_cleanup_failure.cr",
      __DIR__
    )

    result = run_autoconfiguration_fixture(fixture)

    result[:status].success?.should be_true
    result[:error].should eq("")
  end

  it "keeps package-specific logic out of Application and DI" do
    application_source = File.read(
      File.expand_path("../src/opal/application.cr", __DIR__)
    )
    di_source = File.read(File.expand_path("../src/opal/di.cr", __DIR__))

    application_source.should_not contain("LF::Data")
    application_source.should_not contain("LF::HTTP")
    di_source.should_not contain("ApplicationAutoConfiguration")
    di_source.should_not contain("ApplicationExtension")
  end
end
