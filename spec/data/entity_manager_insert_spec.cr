require "./spec_helper"
require "../../src/opal/data"
require "../../src/opal/data/dialects/sqlite"
require "./support/sqlite_database"

private module InsertValueConverter
  def self.load(result : DB::ResultSet) : String
    result.read(String).upcase
  end

  def self.dump(value : String) : String
    value.downcase
  end
end

@[LF::Data::Table("assigned_insert_records")]
private class AssignedInsertRecord
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : String

  @[LF::Data::Column(converter: InsertValueConverter)]
  getter value : String

  getter note : String?

  def initialize(@id : String, @value : String, @note : String?)
  end
end

@[LF::Data::Table("generated_insert_records")]
private class GeneratedInsertRecord
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  getter value : String

  def initialize(@value : String)
    @id = nil
  end
end

@[LF::Data::Table("generated_int32_records")]
private class GeneratedInt32Record
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int32?

  getter value : String

  def initialize(@value : String)
    @id = nil
  end
end

private class InsertListener
  include LF::Data::Listener

  getter statements = [] of LF::Data::StatementCompletionEvent

  def on_statement_completion(event : LF::Data::StatementCompletionEvent) : Nil
    @statements << event
  end
end

private class ReturningSQLiteDialect < LF::Data::Dialects::SQLite
  module ReturningPolicy
    IDENTIFIER_OPEN        = %(")
    IDENTIFIER_CLOSE       = %(")
    IDENTIFIER_ESCAPE_FROM = %(")
    IDENTIFIER_ESCAPE_TO   = %("")
    PLACEHOLDER_STYLE      = :anonymous
    PLACEHOLDER_TOKEN      = "?"
    EMPTY_INSERT_STYLE     = :default_values
    GENERATED_KEY_SOURCE   = LF::Data::SQL::GeneratedKeySource::ReturningRow
  end

  STATIC_SQL_POLICY = ReturningPolicy
end

private def prepare_insert_tables(database : DB::Database)
  database.exec(
    "CREATE TABLE assigned_insert_records " \
    "(id TEXT PRIMARY KEY, value TEXT NOT NULL, note TEXT)"
  )
  database.exec(
    "CREATE TABLE generated_insert_records " \
    "(id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT NOT NULL)"
  )
  database.exec(
    "CREATE TABLE generated_int32_records " \
    "(id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT NOT NULL)"
  )
end

describe LF::Data::EntityManager do
  it "inserts assigned IDs with converted and nilable values" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      prepare_insert_tables(database)
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )
      entity = AssignedInsertRecord.new("key", "MixedCase", nil)

      source.transaction { |manager| manager.persist(entity) }

      database.query_one(
        "SELECT id, value, note FROM assigned_insert_records"
      ) do |result|
        result.read(String).should eq("key")
        result.read(String).should eq("mixedcase")
        result.read(String?).should be_nil
      end
    end
  end

  it "applies a generated Int64 ID only when flush succeeds" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      prepare_insert_tables(database)
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )
      entity = GeneratedInsertRecord.new("value")

      source.transaction do |manager|
        manager.persist(entity)
        entity.id.should be_nil
        manager.flush
        entity.id.should_not be_nil
      end

      database.scalar("SELECT value FROM generated_insert_records")
        .should eq("value")
    end
  end

  it "reports successful INSERT statements" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      prepare_insert_tables(database)
      listener = InsertListener.new
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new,
        listeners: [listener] of LF::Data::Listener
      )

      source.transaction do |manager|
        manager.persist(AssignedInsertRecord.new("key", "value", "note"))
      end

      listener.statements.size.should eq(1)
      event = listener.statements.first
      event.operation.should eq(LF::Data::StatementOperation::Insert)
      event.entity_name.should eq("AssignedInsertRecord")
      event.rows_affected.should eq(1_i64)
      event.error.should be_nil
    end
  end

  it "propagates a uniqueness error and marks the manager failed" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      prepare_insert_tables(database)
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )
      escaped = nil.as(LF::Data::EntityManager?)

      error = expect_raises(SQLite3::Exception) do
        source.transaction do |manager|
          escaped = manager
          manager.persist(AssignedInsertRecord.new("dup", "first", nil))
          manager.persist(AssignedInsertRecord.new("dup", "second", nil))
          manager.flush
        end
      end

      error.should_not be_a(LF::Data::Error)
      expect_raises(LF::Data::FailedEntityManagerError) do
        escaped.not_nil!.persist(AssignedInsertRecord.new("other", "value", nil))
      end
      database.exec(
        "INSERT INTO \"assigned_insert_records\" " \
        "(\"id\", \"value\", \"note\") VALUES (?, ?, ?)",
        "statement-reset",
        "value",
        nil
      )
      database.exec(
        "DELETE FROM assigned_insert_records WHERE id = ?",
        "statement-reset"
      )
      database.scalar("SELECT count(*) FROM assigned_insert_records").should eq(0_i64)
    end
  end

  it "rolls back when a generated Int64 cannot fit an Int32 entity ID" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      prepare_insert_tables(database)
      database.exec(
        "INSERT INTO sqlite_sequence (name, seq) VALUES (?, ?)",
        "generated_int32_records",
        Int32::MAX.to_i64
      )
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )
      entity = GeneratedInt32Record.new("overflow")

      expect_raises(OverflowError) do
        source.transaction do |manager|
          manager.persist(entity)
          manager.flush
        end
      end

      entity.id.should be_nil
      database.scalar("SELECT count(*) FROM generated_int32_records").should eq(0_i64)
    end
  end

  it "reads generated IDs from a ReturningRow plan" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      prepare_insert_tables(database)
      source = LF::Data::DataSource.new(
        database,
        dialect: ReturningSQLiteDialect.new
      )
      entity = GeneratedInsertRecord.new("returning")

      source.transaction do |manager|
        manager.persist(entity)
        manager.flush
      end

      entity.id.should_not be_nil
      database.scalar("SELECT value FROM generated_insert_records")
        .should eq("returning")
    end
  end
end
