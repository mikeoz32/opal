require "./spec_helper"
require "../../src/opal/data"
require "../../src/opal/data/dialects/sqlite"
require "./support/sqlite_database"

struct JSONColumnAddress
  include JSON::Serializable

  getter city : String
  getter lines : Array(String)

  def initialize(@city : String, @lines : Array(String))
  end
end

struct JSONColumnCreated
  include JSON::Serializable

  getter created_id : String

  def initialize(@created_id : String)
  end
end

struct JSONColumnArchived
  include JSON::Serializable

  getter archived_reason : String

  def initialize(@archived_reason : String)
  end
end

alias JSONColumnPayload = JSONColumnCreated | JSONColumnArchived

struct JSONColumnOpaque
  getter value : String

  def initialize(@value : String)
  end
end

module JSONColumnOpaqueCodec
  def self.load(parser : JSON::PullParser, type : JSONColumnOpaque.class) : JSONColumnOpaque
    JSONColumnOpaque.new(parser.read_string.reverse)
  end

  def self.dump(value : JSONColumnOpaque, builder : JSON::Builder) : Nil
    builder.string(value.value.reverse)
  end
end

module JSONColumnFailingCodec
  def self.load(parser : JSON::PullParser, type : JSONColumnOpaque.class) : JSONColumnOpaque
    raise "private decode detail"
  end

  def self.dump(value : JSONColumnOpaque, builder : JSON::Builder) : Nil
    raise "private encode detail"
  end
end

@[LF::Data::Table("json_column_records")]
private class JSONColumnRecord
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::Column(type: :jsonb)]
  property payload : JSONColumnPayload

  @[LF::Data::Column(type: :json)]
  property tags : Array(String)

  @[LF::Data::Column(type: :jsonb)]
  property address : JSONColumnAddress?

  @[LF::Data::Column(type: :jsonb, codec: JSONColumnOpaqueCodec)]
  property opaque : JSONColumnOpaque

  def initialize(@id, @payload, @tags, @address, @opaque)
  end
end

@[LF::Data::Table("failing_json_column_records")]
private class FailingJSONColumnRecord
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::Column(type: :jsonb, codec: JSONColumnFailingCodec)]
  getter payload : JSONColumnOpaque

  def initialize(@id, @payload)
  end
end

private def with_json_column_source(&)
  LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
    database.exec(
      "CREATE TABLE json_column_records (" \
      "id INTEGER PRIMARY KEY, payload TEXT NOT NULL, tags TEXT NOT NULL, " \
      "address TEXT, opaque TEXT NOT NULL)"
    )
    source = LF::Data::DataSource.new(
      database,
      dialect: LF::Data::Dialects::SQLite.new
    )
    begin
      yield source, database
    ensure
      source.close
    end
  end
end

describe LF::Data::JSONColumn do
  it "round-trips nested, array, union, nilable, and custom-codec values" do
    with_json_column_source do |source, database|
      original = JSONColumnRecord.new(
        7_i64,
        JSONColumnCreated.new("change-7"),
        ["data", "release"],
        JSONColumnAddress.new("Kyiv", ["Line 1", "Line 2"]),
        JSONColumnOpaque.new("secret")
      )

      source.transaction do |manager|
        manager.persist(original)
        manager.flush
      end

      stored = database.query_one(
        "SELECT payload, tags, address, opaque FROM json_column_records WHERE id = 7",
        as: {String, String, String, String}
      )
      JSON.parse(stored[0])["created_id"].as_s.should eq("change-7")
      JSON.parse(stored[1]).as_a.map(&.as_s).should eq(["data", "release"])
      JSON.parse(stored[2])["city"].as_s.should eq("Kyiv")
      stored[3].should eq(%("terces"))

      loaded = source.transaction do |manager|
        manager.find(JSONColumnRecord, 7_i64).not_nil!
      end
      loaded.payload.should eq(JSONColumnCreated.new("change-7"))
      loaded.tags.should eq(["data", "release"])
      loaded.address.should eq(JSONColumnAddress.new("Kyiv", ["Line 1", "Line 2"]))
      loaded.opaque.should eq(JSONColumnOpaque.new("secret"))
    end
  end

  it "maps SQL NULL without invoking the codec" do
    with_json_column_source do |source, database|
      database.exec(
        "INSERT INTO json_column_records " \
        "(id, payload, tags, address, opaque) VALUES (?, ?, ?, NULL, ?)",
        8_i64,
        %({"archived_reason":"superseded"}),
        %([]),
        %("eulav")
      )

      loaded = source.transaction do |manager|
        manager.find(JSONColumnRecord, 8_i64).not_nil!
      end
      loaded.payload.should eq(JSONColumnArchived.new("superseded"))
      loaded.address.should be_nil
      loaded.opaque.should eq(JSONColumnOpaque.new("value"))
    end
  end

  it "serializes default and custom-codec values in equality predicates" do
    with_json_column_source do |source, _database|
      record = JSONColumnRecord.new(
        11_i64,
        JSONColumnCreated.new("change-11"),
        ["release"],
        nil,
        JSONColumnOpaque.new("lookup")
      )
      source.transaction do |manager|
        manager.persist(record)
      end

      fields = JSONColumnRecord::Fields
      matching = source.transaction do |manager|
        manager.query(JSONColumnRecord)
          .where(fields.payload.eq(JSONColumnCreated.new("change-11")))
          .where(fields.opaque.eq(JSONColumnOpaque.new("lookup")))
          .to_a
      end

      matching.map(&.id).should eq([11_i64])
    end
  end

  it "wraps malformed JSON in typed decode and mapping errors without payload data" do
    with_json_column_source do |source, database|
      database.exec(
        "INSERT INTO json_column_records " \
        "(id, payload, tags, address, opaque) VALUES (?, ?, ?, NULL, ?)",
        9_i64,
        %({"private":"broken"),
        %([]),
        %("eulav")
      )

      error = expect_raises(LF::Data::MappingError) do
        source.transaction { |manager| manager.find(JSONColumnRecord, 9_i64) }
      end
      error.property.should eq("payload")
      error.column.should eq("payload")
      error.cause.should be_a(LF::Data::JSONColumnDecodeError)
      error.message.not_nil!.should_not contain("private")
      error.cause.not_nil!.message.not_nil!.should_not contain("private")
    end
  end

  it "rejects trailing content that a codec leaves unread" do
    with_json_column_source do |source, database|
      database.exec(
        "INSERT INTO json_column_records " \
        "(id, payload, tags, address, opaque) VALUES (?, ?, ?, NULL, ?)",
        12_i64,
        %({"created_id":"first"} {"created_id":"private"}),
        %([]),
        %("eulav")
      )

      error = expect_raises(LF::Data::MappingError) do
        source.transaction { |manager| manager.find(JSONColumnRecord, 12_i64) }
      end
      error.cause.should be_a(LF::Data::JSONColumnDecodeError)
      error.cause.not_nil!.message.not_nil!.should_not contain("private")
    end
  end

  it "uses typed codec errors for custom encode failures" do
    record = FailingJSONColumnRecord.new(1_i64, JSONColumnOpaque.new("private"))

    error = expect_raises(LF::Data::JSONColumnEncodeError) do
      record.__lf_insert_args
    end
    error.target_type.should eq("JSONColumnOpaque")
    error.message.not_nil!.should_not contain("private")
    error.cause.not_nil!.message.should eq("private encode detail")
  end

  it "uses typed codec errors for custom decode failures" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      error = expect_raises(LF::Data::MappingError) do
        database.query_one(%(SELECT 1 AS id, '"value"' AS payload)) do |result|
          FailingJSONColumnRecord.__lf_hydrate(result)
        end
      end

      error.property.should eq("payload")
      decode = error.cause.should be_a(LF::Data::JSONColumnDecodeError)
      decode.as(LF::Data::JSONColumnDecodeError).target_type.should eq("JSONColumnOpaque")
      error.message.not_nil!.should_not contain("private")
      decode.as(LF::Data::JSONColumnDecodeError).message.not_nil!.should_not contain("private")
    end
  end

  it "reports a typed storage error when a driver returns a non-JSON value" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      error = expect_raises(LF::Data::MappingError) do
        database.query_one(
          %(SELECT 10 AS id, 42 AS payload, '[]' AS tags, NULL AS address, '"eulav"' AS opaque)
        ) do |result|
          JSONColumnRecord.__lf_hydrate(result)
        end
      end

      storage = error.cause.should be_a(LF::Data::JSONColumnStorageError)
      storage.as(LF::Data::JSONColumnStorageError).stored_type.should eq("Int64")
      storage.as(LF::Data::JSONColumnStorageError).target_type.should contain("JSONColumn")
    end
  end
end
