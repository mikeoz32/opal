require "./spec_helper"
require "../../src/opal/data"
require "../../src/opal/data/dialects/sqlite"
require "./support/sqlite_database"

private class FlushFailure < Exception
end

private module FlushConverter
  def self.load(result : DB::ResultSet) : String
    result.read(String)
  end

  def self.dump(value : String) : String
    raise FlushFailure.new("converter failed") if value == "fail"
    value
  end
end

@[LF::Data::Table("flush_records")]
private class FlushRecord
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : String

  @[LF::Data::Column(converter: FlushConverter)]
  getter value : String

  def initialize(@id : String, @value : String)
  end
end

private class FlushListener
  include LF::Data::Listener

  getter statements = [] of LF::Data::StatementCompletionEvent

  def on_statement_completion(event : LF::Data::StatementCompletionEvent) : Nil
    @statements << event
  end
end

describe LF::Data::EntityManager do
  it "performs no statement for repeated no-op flushes" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.exec(
        "CREATE TABLE flush_records (id TEXT PRIMARY KEY, value TEXT NOT NULL)"
      )
      listener = FlushListener.new
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new,
        listeners: [listener] of LF::Data::Listener
      )

      source.transaction do |manager|
        manager.flush
        manager.flush
      end

      listener.statements.should be_empty
    end
  end

  it "stops at the failed operation, rolls back earlier work, and becomes terminal" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.exec(
        "CREATE TABLE flush_records (id TEXT PRIMARY KEY, value TEXT NOT NULL)"
      )
      listener = FlushListener.new
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new,
        listeners: [listener] of LF::Data::Listener
      )
      escaped = nil.as(LF::Data::EntityManager?)
      first = FlushRecord.new("first", "ok")
      failed = FlushRecord.new("failed", "fail")
      skipped = FlushRecord.new("skipped", "ok")

      error = expect_raises(FlushFailure) do
        source.transaction do |manager|
          escaped = manager
          manager.persist(first)
          manager.persist(failed)
          manager.persist(skipped)
          manager.flush
        end
      end

      error.message.should eq("converter failed")
      listener.statements.map(&.entity_name).should eq(["FlushRecord"])
      database.scalar("SELECT count(*) FROM flush_records").should eq(0_i64)

      terminal = escaped.not_nil!
      {
        :persist => -> { terminal.persist(FlushRecord.new("other", "ok")) },
        :remove  => -> { terminal.remove(first) },
        :find    => -> { terminal.find(FlushRecord, "first") },
        :flush   => -> { terminal.flush },
      }.each do |operation, invoke|
        failure = expect_raises(LF::Data::FailedEntityManagerError) { invoke.call }
        failure.operation.should eq(operation)
        failure.cause.should be(error)
      end

      terminal.close
      terminal.close
    end
  end
end
