require "./spec_helper"
require "../../src/opal/data"

describe LF::Data::Entity do
  it "installs on a class with a generated integer ID" do
    fixture = File.expand_path("../fixtures/data/entities/valid_generated_id.cr", __DIR__)
    result = LF::DataSpecSupport.compile_fixture(fixture)

    result[:status].success?.should be_true
    result[:error].should eq("")
  end

  it "installs on a class with an assigned portable ID" do
    fixture = File.expand_path("../fixtures/data/entities/valid_assigned_id.cr", __DIR__)
    result = LF::DataSpecSupport.compile_fixture(fixture)

    result[:status].success?.should be_true
    result[:error].should eq("")
  end

  it "does not discover entities globally" do
    source = File.read(File.expand_path("../../src/opal/data/entity.cr", __DIR__))

    source.should_not contain("Object.all_subclasses")
  end

  it "rejects converter methods with incompatible return types" do
    fixture = File.expand_path("../fixtures/data/entities/invalid_converter.cr", __DIR__)
    result = LF::DataSpecSupport.compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain("InvalidStoredValue")
    result[:error].should contain("DB::Any")
  end

  it "rejects converter load methods with incompatible return types" do
    fixture = File.expand_path("../fixtures/data/entities/invalid_load_converter.cr", __DIR__)
    result = LF::DataSpecSupport.compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain("can't cast Int32 to String")
  end

  {
    {"struct_entity.cr", "StructEntity", "reference class"},
    {"missing_id.cr", "MissingIdEntity", "exactly one LF::Data::Id"},
    {"multiple_ids.cr", "MultipleIdsEntity", "tenant_id, record_id"},
    {"duplicate_columns.cr", "DuplicateColumnsEntity", "column value"},
    {"invalid_generated_id.cr", "InvalidGeneratedIdEntity", "field id"},
    {"invalid_version_type.cr", "InvalidVersionTypeEntity", "field version"},
    {"writable_version.cr", "WritableVersionEntity", "public setter version="},
    {"unsupported_direct_type.cr", "UnsupportedDirectTypeEntity", "field amount"},
    {"invalid_table_name.cr", "InvalidTableNameEntity", "table name"},
    {"invalid_column_name.cr", "InvalidColumnNameEntity", "column name for field payload"},
    {"invalid_ignored_field.cr", "InvalidIgnoredFieldEntity", "ignored field derived_label"},
  }.each do |fixture_case|
    fixture_name, entity_name, message_fragment = fixture_case

    it "rejects #{fixture_name}" do
      fixture = File.expand_path("../fixtures/data/entities/#{fixture_name}", __DIR__)
      result = LF::DataSpecSupport.compile_fixture(fixture)

      result[:status].success?.should be_false
      result[:error].should contain(entity_name)
      result[:error].should contain(message_fragment)
    end
  end
end
