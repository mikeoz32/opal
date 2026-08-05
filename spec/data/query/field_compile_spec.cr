require "../spec_helper"
require "../../../src/opal/data"

private module FieldStringConverter
  def self.load(result : DB::ResultSet) : String
    result.read(String)
  end

  def self.dump(value : String) : String
    value.downcase
  end
end

private class FieldEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::Column(name: "stored_name", converter: FieldStringConverter)]
  getter display_name : String

  getter note : String?

  @[LF::Data::Column(ignore: true)]
  getter transient : String = "ignored"

  def initialize(@id : Int64, @display_name : String, @note : String?)
  end
end

describe LF::Data::Query::Field do
  it "generates unique marker and descriptor types for persistent fields" do
    typeof(FieldEntity::Fields.id).should_not eq(typeof(FieldEntity::Fields.display_name))
    typeof(FieldEntity::Fields.display_name).should_not eq(typeof(FieldEntity::Fields.note))
  end

  it "retains entity, property, and column information statically" do
    typeof(FieldEntity::Fields.id).entity_type.should eq(FieldEntity)
    typeof(FieldEntity::Fields.id).property_type.should eq(Int64)
    FieldEntity::Fields.display_name.column.should eq("stored_name")
    FieldEntity::Fields.note.column.should eq("note")
  end

  it "dumps direct, converted, and nilable values with exact types" do
    FieldEntity::Fields.id.dump(3_i64).should eq(3_i64)
    FieldEntity::Fields.display_name.dump("Mixed").should eq("mixed")
    FieldEntity::Fields.note.dump(nil).should be_nil
    FieldEntity::Fields.note.dump("text").should eq("text")
  end

  it "does not generate descriptors for ignored fields" do
    FieldEntity::Fields.responds_to?(:transient).should be_false
  end

  {
    {"query_wrong_value.cr", "PropertyType"},
    {"query_like_non_string.cr", "LIKE"},
    {"query_nil_non_nil.cr", "nil predicate"},
    {"query_nil_order.cr", "NULL ordering"},
    {"query_nil_non_nullable.cr", "nil predicate"},
    {"query_static_in_nil.cr", "NULL values"},
    {"query_static_in_nilable.cr", "NULL values"},
    {"query_order_bool.cr", "not orderable"},
    {"query_static_array_in.cr", "__lf_tokens"},
    {"query_cross_entity_predicate.cr", "belongs to"},
    {"query_cross_entity_order.cr", "belongs to"},
    {"dynamic_query_cross_entity.cr", "belongs to"},
  }.each do |fixture_case|
    fixture_name, message = fixture_case

    it "rejects #{fixture_name}" do
      fixture = File.expand_path("../../fixtures/data/#{fixture_name}", __DIR__)
      result = LF::DataSpecSupport.compile_fixture(fixture)

      result[:status].success?.should be_false
      result[:error].should contain(message)
    end
  end
end
