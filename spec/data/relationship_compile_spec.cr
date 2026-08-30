require "./spec_helper"
require "../../src/opal/data"

describe "entity relationships" do
  it "accepts explicit belongs_to, has_many, and has_one declarations" do
    fixture = File.expand_path(
      "../fixtures/data/relationships_valid.cr",
      __DIR__
    )
    result = LF::DataSpecSupport.compile_fixture(fixture)

    result[:status].success?.should be_true
    result[:error].should eq("")
  end

  {
    {"relationships_missing_foreign_key.cr", "missing foreign-key field \"parent_id\""},
    {"relationships_wrong_foreign_key_type.cr", "foreign-key field \"parent_id\""},
    {"relationships_invalid_belongs_to_remove.cr", "does not allow cascade_remove"},
    {"relationships_invalid_collection.cr", "must be Array"},
    {"relationships_orphan_removal.cr", "orphan removal is not supported"},
    {"relationships_invalid_cascade_flag.cr", "cascade_persist must be a Bool literal"},
    {"relationships_missing_inverse.cr", "requires an inverse belongs_to"},
  }.each do |fixture_case|
    fixture_name, message = fixture_case

    it "rejects #{fixture_name}" do
      fixture = File.expand_path("../fixtures/data/#{fixture_name}", __DIR__)
      result = LF::DataSpecSupport.compile_fixture(fixture)

      result[:status].success?.should be_false
      result[:error].should contain(message)
    end
  end
end
