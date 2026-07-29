require "./spec_helper"
require "../../src/opal/data"
require "./support/sqlite_database"
require "uuid"

private module UUIDAsString
  def self.load(result : DB::ResultSet) : UUID
    UUID.new(result.read(String))
  end

  def self.dump(value : UUID) : DB::Any
    value.to_s
  end
end

private enum ConverterStatus
  Pending
  Complete
end

private module StatusAsString
  def self.load(result : DB::ResultSet) : ConverterStatus
    ConverterStatus.parse(result.read(String))
  end

  def self.dump(value : ConverterStatus) : DB::Any
    value.to_s
  end
end

private module RaisingConverter
  def self.load(result : DB::ResultSet) : String
    raise "load failed"
  end

  def self.dump(value : String) : DB::Any
    raise "dump failed"
  end
end

private module NilProbeConverter
  class_getter calls = 0

  def self.dump(value : String) : DB::Any
    @@calls += 1
    value
  end
end

describe LF::Data::Converter do
  it "loads and dumps UUID values without a registry" do
    value = UUID.random

    LF::Data::Converter.dump(value, UUIDAsString).should eq(value.to_s)
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.query_one("SELECT ?", value.to_s) do |result|
        LF::Data::Converter.load(result, UUIDAsString, UUID).should eq(value)
      end
    end
  end

  it "loads and dumps enum values" do
    LF::Data::Converter.dump(ConverterStatus::Complete, StatusAsString)
      .should eq("Complete")
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.query_one("SELECT 'Pending'") do |result|
        LF::Data::Converter.load(result, StatusAsString, ConverterStatus)
          .should eq(ConverterStatus::Pending)
      end
    end
  end

  it "does not invoke a converter for nil dump values" do
    calls = NilProbeConverter.calls

    LF::Data::Converter.dump(nil, NilProbeConverter).should be_nil

    NilProbeConverter.calls.should eq(calls)
  end

  it "propagates converter failures unchanged" do
    dump_error = expect_raises(Exception, "dump failed") do
      LF::Data::Converter.dump("value", RaisingConverter)
    end

    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      load_error = expect_raises(Exception, "load failed") do
        database.query_one("SELECT 'value'") do |result|
          LF::Data::Converter.load(result, RaisingConverter, String)
        end
      end

      load_error.message.should eq("load failed")
    end
    dump_error.message.should eq("dump failed")
  end

  it "does not maintain a global converter registry" do
    source = File.read(File.expand_path("../../src/opal/data/converter.cr", __DIR__))

    source.should_not contain("Hash(")
    source.should_not contain("all_subclasses")
  end
end
