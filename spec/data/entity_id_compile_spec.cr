require "./spec_helper"
require "../../src/opal/data"

describe "typed entity IDs" do
  it "accepts the declared non-nil ID type for lookup and delete" do
    fixture = File.expand_path(
      "../fixtures/data/entity_id_valid_operations.cr",
      __DIR__
    )
    result = LF::DataSpecSupport.compile_fixture(fixture)

    result[:status].success?.should be_true
    result[:error].should eq("")
  end

  {
    "entity_id_wrong_find.cr",
    "entity_id_nil_find.cr",
    "entity_id_cross_entity_find.cr",
    "entity_id_wrong_delete.cr",
    "entity_id_nil_delete.cr",
  }.each do |fixture_name|
    it "rejects #{fixture_name}" do
      fixture = File.expand_path("../fixtures/data/#{fixture_name}", __DIR__)
      result = LF::DataSpecSupport.compile_fixture(fixture)

      result[:status].success?.should be_false
      result[:error].should contain("__lf_find_args")
    end
  end
end
