require "spec"
require "pg"
require "../src/opal/data"
require "../src/opal/data/dialects/postgresql"

POSTGRESQL_JSON_URL = ENV["OPAL_POSTGRESQL_URL"]? || raise(
  "OPAL_POSTGRESQL_URL is required for PostgreSQL JSON column specs"
)

struct PostgreSQLJSONCreated
  include JSON::Serializable

  getter created_id : String
  getter attributes : Hash(String, String)

  def initialize(@created_id : String, @attributes : Hash(String, String))
  end
end

struct PostgreSQLJSONArchived
  include JSON::Serializable

  getter archived_reason : String

  def initialize(@archived_reason : String)
  end
end

alias PostgreSQLJSONPayload = PostgreSQLJSONCreated | PostgreSQLJSONArchived

struct PostgreSQLJSONMetadata
  include JSON::Serializable

  getter source : String

  def initialize(@source : String)
  end
end

@[LF::Data::Table("opal_pg_json_records")]
private class PostgreSQLJSONRecord
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::Column(type: :jsonb)]
  property payload : PostgreSQLJSONPayload

  @[LF::Data::Column(type: :json)]
  property tags : Array(String)

  @[LF::Data::Column(type: :jsonb)]
  property metadata : PostgreSQLJSONMetadata?

  def initialize(@id, @payload, @tags, @metadata)
  end
end

private class CreatePostgreSQLJSONRecords < LF::Data::Migration
  def version : Int64
    40_i64
  end

  def name : String
    "create_postgresql_json_records"
  end

  def up(schema : LF::Data::SchemaEditor) : Nil
    schema.create_table("opal_pg_json_records") do |table|
      table.int64("id", null: false)
      table.jsonb("payload", null: false)
      table.json("tags", null: false)
      table.jsonb("metadata")
      table.primary_key("id")
    end
  end
end

private def reset_postgresql_json_columns : Nil
  DB.open(POSTGRESQL_JSON_URL) do |database|
    database.exec("DROP TABLE IF EXISTS opal_pg_json_records CASCADE")
    database.exec("DROP TABLE IF EXISTS _lf_migrations CASCADE")
  end
end

describe "PostgreSQL typed JSON columns" do
  before_each { reset_postgresql_json_columns }
  after_each { reset_postgresql_json_columns }

  it "round-trips typed values and executes native JSONB predicates" do
    source = nil.as(LF::Data::DataSource?)
    source = LF::Data::DataSource.open(
      POSTGRESQL_JSON_URL,
      dialect: LF::Data::Dialects::PostgreSQL.new
    )
    LF::Data::MigrationRunner.new(
      source,
      lock_namespace: "opal-postgresql-json",
      lock_timeout: 2.seconds
    ).run(LF::Data::MigrationSet.new(CreatePostgreSQLJSONRecords.new))

    record = PostgreSQLJSONRecord.new(
      1_i64,
      PostgreSQLJSONCreated.new("change-1", {"status" => "ready"}),
      ["release", "data"],
      PostgreSQLJSONMetadata.new("integration")
    )
    source.transaction do |manager|
      manager.persist(record)
      manager.flush
    end

    loaded = source.transaction do |manager|
      manager.find(PostgreSQLJSONRecord, 1_i64).not_nil!
    end
    loaded.payload.should eq(record.payload)
    loaded.tags.should eq(["release", "data"])
    loaded.metadata.should eq(PostgreSQLJSONMetadata.new("integration"))

    fields = PostgreSQLJSONRecord::Fields
    source.transaction do |manager|
      repository = manager.repository(PostgreSQLJSONRecord)
      repository.query
        .where(fields.payload.jsonb_contains({created_id: "change-1"}))
        .where(fields.payload.jsonb_has_key("attributes"))
        .to_a.map(&.id).should eq([1_i64])

      loaded.payload = PostgreSQLJSONArchived.new("superseded")
      loaded.metadata = nil
      manager.persist(loaded)
      manager.flush
    end

    updated = source.transaction do |manager|
      manager.repository(PostgreSQLJSONRecord).find(1_i64).not_nil!
    end
    updated.payload.should eq(PostgreSQLJSONArchived.new("superseded"))
    updated.metadata.should be_nil

    snapshot = source.inspect_schema
    table = snapshot.table("opal_pg_json_records").not_nil!
    table.column("payload").not_nil!.type.jsonb?.should be_true
    table.column("tags").not_nil!.type.json?.should be_true
    table.column("metadata").not_nil!.type.jsonb?.should be_true
  ensure
    source.try &.close
  end
end
