require "./spec_helper"
require "../../src/opal/data"
require "./support/sqlite_database"

private module UppercaseConverter
  def self.load(result : DB::ResultSet) : String
    result.read(String).upcase
  end

  def self.dump(value : String) : DB::Any
    value.downcase
  end
end

private class HydrationRecord
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::Column(name: "summary")]
  getter title : String

  getter note : String?

  @[LF::Data::Column(converter: UppercaseConverter)]
  getter code : String

  @[LF::Data::Column(ignore: true)]
  getter display_label : String = "hydrated"

  def initialize(@id : Int64, @title : String, @note : String?, @code : String)
    raise "domain constructor must not hydrate persisted state"
  end
end

describe LF::Data::Entity do
  it "hydrates persistent state without invoking the domain constructor" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      record = database.query_one(
        "SELECT 7 AS id, 'stored' AS summary, NULL AS note, 'abc' AS code"
      ) do |result|
        HydrationRecord.__lf_hydrate(result)
      end

      record.id.should eq(7_i64)
      record.title.should eq("stored")
      record.note.should be_nil
      record.code.should eq("ABC")
      record.display_label.should eq("hydrated")
    end
  end

  it "rejects missing columns" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      error = expect_raises(LF::Data::MappingError) do
        database.query_one("SELECT 7 AS id, 'stored' AS summary, NULL AS note") do |result|
          HydrationRecord.__lf_hydrate(result)
        end
      end

      error.entity.should eq("HydrationRecord")
      error.column.should eq("code")
    end
  end

  it "rejects unexpected columns" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      error = expect_raises(LF::Data::MappingError) do
        database.query_one(
          "SELECT 7 AS id, 'stored' AS summary, NULL AS note, 'abc' AS code, 1 AS extra"
        ) do |result|
          HydrationRecord.__lf_hydrate(result)
        end
      end

      error.entity.should eq("HydrationRecord")
      error.column.should eq("extra")
    end
  end

  it "rejects columns in a different order" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      error = expect_raises(LF::Data::MappingError) do
        database.query_one(
          "SELECT 'stored' AS summary, 7 AS id, NULL AS note, 'abc' AS code"
        ) do |result|
          HydrationRecord.__lf_hydrate(result)
        end
      end

      error.column.should eq("summary")
    end
  end

  it "wraps null and incompatible direct values with mapping context" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      error = expect_raises(LF::Data::MappingError) do
        database.query_one(
          "SELECT 7 AS id, NULL AS summary, NULL AS note, 'abc' AS code"
        ) do |result|
          HydrationRecord.__lf_hydrate(result)
        end
      end

      error.entity.should eq("HydrationRecord")
      error.property.should eq("title")
      error.column.should eq("summary")
      error.cause.should be_a(DB::ColumnTypeMismatchError)
    end
  end
end
