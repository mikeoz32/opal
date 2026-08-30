require "./spec_helper"
require "../../src/opal/data"

describe "typed repository compilation" do
  it "accepts each entity's exact lookup ID type" do
    fixture = File.expand_path(
      "../fixtures/data/repositories_valid.cr",
      __DIR__
    )
    result = LF::DataSpecSupport.compile_fixture(fixture)

    result[:status].success?.should be_true
    result[:error].should eq("")
  end

  it "rejects a wrong repository lookup ID type" do
    fixture = File.expand_path(
      "../fixtures/data/repositories_wrong_id.cr",
      __DIR__
    )
    result = LF::DataSpecSupport.compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain("Int64")
    result[:error].should contain("String")
  end

  it "rejects an entity from another repository" do
    fixture = File.expand_path(
      "../fixtures/data/repositories_wrong_entity.cr",
      __DIR__
    )
    result = LF::DataSpecSupport.compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain("GeneratedRepositoryEntity")
    result[:error].should contain("OtherRepositoryEntity")
  end

  it "requires explicit ordering for composed pagination" do
    fixture = File.expand_path(
      "../fixtures/data/repositories_unordered_page.cr",
      __DIR__
    )
    result = LF::DataSpecSupport.compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain("requires at least one order_by")
  end
end
