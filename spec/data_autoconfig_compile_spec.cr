require "./spec_helper"

private def compile_data_autoconfig_fixture(path : String)
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

describe "Data application autoconfiguration compiler" do
  it "compiles a marked Application" do
    fixture = File.expand_path("fixtures/data/autoconfig_application.cr", __DIR__)
    result = compile_data_autoconfig_fixture(fixture)

    result[:status].success?.should be_true
    result[:error].should eq("")
  end

  it "can be required without declaring an Application" do
    fixture = File.expand_path(
      "fixtures/data/autoconfig_without_application.cr",
      __DIR__
    )
    result = compile_data_autoconfig_fixture(fixture)

    result[:status].success?.should be_true
    result[:error].should eq("")
  end

  it "installs nothing when the Application marker is absent" do
    fixture = File.expand_path("fixtures/data/autoconfig_without_marker.cr", __DIR__)
    result = compile_data_autoconfig_fixture(fixture)

    result[:status].success?.should be_true
    result[:error].should eq("")
  end

  it "rejects the Data marker on a non-Application class" do
    fixture = File.expand_path(
      "fixtures/data/autoconfig_marker_without_application.cr",
      __DIR__
    )
    result = compile_data_autoconfig_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain(
      "@[LF::AutoConfig::Data] requires @[LF::Application] on " \
      "DataAutoconfigNotAnApplication"
    )
  end

  it "keeps the Data adapter out of the root opal entrypoint" do
    fixture = File.expand_path(
      "fixtures/data/opal_without_data_autoconfig.cr",
      __DIR__
    )
    result = compile_data_autoconfig_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain("undefined constant LF::AutoConfig::Data")
  end
end
