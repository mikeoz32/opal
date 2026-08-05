require "./spec_helper"
require "../../src/opal/data/dialects/sqlite"
require "./support/sqlite_database"

private class HistorySpecMigration < LF::Data::Migration
  getter version : Int64
  getter name : String

  def initialize(@version : Int64, @name : String)
  end

  def up(schema : LF::Data::SchemaEditor) : Nil
  end
end

describe LF::Data::MigrationHistory do
  it "creates its history table idempotently with the required schema" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.using_connection do |connection|
        history = LF::Data::MigrationHistory.new(
          connection,
          LF::Data::Dialects::SQLite.new
        )

        2.times { history.ensure_table }

        columns = [] of {String, String, Int64, Int64}
        connection.query(%(PRAGMA table_info("_lf_migrations"))) do |result|
          while result.move_next
            result.read(Int64)
            name = result.read(String)
            type = result.read(String)
            not_null = result.read(Int64)
            result.read(String?)
            primary_key = result.read(Int64)
            columns << {name, type, not_null, primary_key}
          end
        end
        columns.should eq([
          {"version", "INTEGER", 1_i64, 1_i64},
          {"name", "TEXT", 1_i64, 0_i64},
          {"applied_at", "TEXT", 1_i64, 0_i64},
        ])
      end
    end
  end

  it "records migrations and loads them ordered by version" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.using_connection do |connection|
        history = LF::Data::MigrationHistory.new(
          connection,
          LF::Data::Dialects::SQLite.new
        )
        history.ensure_table
        later = Time.utc(2026, 8, 4, 12, 30, 0)
        earlier = Time.utc(2026, 8, 4, 12, 0, 0)

        history.record(HistorySpecMigration.new(20_i64, "second"), later)
        history.record(HistorySpecMigration.new(10_i64, "first"), earlier)

        history.load.map { |entry| {entry.version, entry.name, entry.applied_at} }
          .should eq([
            {10_i64, "first", earlier},
            {20_i64, "second", later},
          ])
      end
    end
  end

  it "returns only migrations not already applied with the same name" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.using_connection do |connection|
        history = LF::Data::MigrationHistory.new(
          connection,
          LF::Data::Dialects::SQLite.new
        )
        first = HistorySpecMigration.new(10_i64, "first")
        second = HistorySpecMigration.new(20_i64, "second")
        history.ensure_table
        history.record(first)

        history.pending(LF::Data::MigrationSet.new(first, second))
          .map(&.version).should eq([20_i64])
      end
    end
  end

  it "rejects applied versions absent from the current migration set" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.using_connection do |connection|
        history = LF::Data::MigrationHistory.new(
          connection,
          LF::Data::Dialects::SQLite.new
        )
        old = HistorySpecMigration.new(5_i64, "old")
        current = HistorySpecMigration.new(10_i64, "current")
        history.ensure_table
        history.record(old)

        error = expect_raises(LF::Data::UnknownAppliedMigrationError) do
          history.pending(LF::Data::MigrationSet.new(current))
        end

        error.version.should eq(5_i64)
        error.applied_name.should eq("old")
        history.load.map(&.version).should eq([5_i64])
      end
    end
  end

  it "rejects a changed name for an applied migration version" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.using_connection do |connection|
        history = LF::Data::MigrationHistory.new(
          connection,
          LF::Data::Dialects::SQLite.new
        )
        history.ensure_table
        history.record(HistorySpecMigration.new(10_i64, "original"))

        error = expect_raises(LF::Data::MigrationHistoryMismatchError) do
          history.pending(
            LF::Data::MigrationSet.new(
              HistorySpecMigration.new(10_i64, "renamed")
            )
          )
        end

        error.version.should eq(10_i64)
        error.expected_name.should eq("renamed")
        error.applied_name.should eq("original")
      end
    end
  end

  it "reports schema, insert, and select statements through its observer" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.using_connection do |connection|
        events = [] of LF::Data::StatementCompletionEvent
        observer = ->(event : LF::Data::StatementCompletionEvent) do
          events << event
          nil
        end
        history = LF::Data::MigrationHistory.new(
          connection,
          LF::Data::Dialects::SQLite.new,
          observer
        )

        history.ensure_table
        history.record(HistorySpecMigration.new(10_i64, "first"))
        history.load

        events.map(&.operation).should eq([
          LF::Data::StatementOperation::Schema,
          LF::Data::StatementOperation::Insert,
          LF::Data::StatementOperation::Select,
        ])
        events.map(&.entity_name).should eq([
          "_lf_migrations",
          "_lf_migrations",
          "_lf_migrations",
        ])
        events.each { |event| event.error.should be_nil }
        events[1].rows_affected.should eq(1_i64)
        events[2].rows_affected.should eq(1_i64)
      end
    end
  end
end
