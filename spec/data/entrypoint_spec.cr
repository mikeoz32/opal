require "./spec_helper"

describe "Data entrypoints" do
  it "compiles the opt-in data entrypoint without loading SQLite" do
    fixture = File.expand_path("../fixtures/data/data_entrypoint.cr", __DIR__)
    result = LF::DataSpecSupport.compile_fixture(fixture)

    result[:status].success?.should be_true
    result[:error].should eq("")
  end

  it "compiles the PostgreSQL dialect entrypoint without loading its driver" do
    fixture = File.expand_path(
      "../fixtures/data/postgresql_dialect_without_driver.cr",
      __DIR__
    )
    result = LF::DataSpecSupport.compile_fixture(fixture)

    result[:status].success?.should be_true
    result[:error].should eq("")
  end

  it "does not expose Data through the root entrypoint" do
    fixture = File.expand_path("../fixtures/data/opal_without_data.cr", __DIR__)
    result = LF::DataSpecSupport.compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain("undefined constant LF::Data")
  end

  it "captures compiler stderr and exit status" do
    fixture = File.expand_path("../fixtures/data/opal_without_data.cr", __DIR__)
    result = LF::DataSpecSupport.compile_fixture(fixture)

    result[:status].exit_code.should_not eq(0)
    result[:output].should eq("")
    result[:error].should_not eq("")
  end
end
