require "./spec_helper"
require "../../src/opal/data/dialects/sqlite"
require "./support/sqlite_database"

private class RunnerSpecMigration < LF::Data::Migration
  property version : Int64
  getter name : String
  getter runs = 0

  def initialize(
    @version : Int64,
    @name : String,
    &@action : LF::Data::SchemaEditor -> Nil
  )
  end

  def up(schema : LF::Data::SchemaEditor) : Nil
    @runs += 1
    @action.call(schema)
  end
end

private class RunnerSpecFailure < Exception
end

private class MutableIdentityMigration < LF::Data::Migration
  property version : Int64
  property name : String

  def initialize(@version : Int64, @name : String)
  end

  def up(schema : LF::Data::SchemaEditor) : Nil
    schema.create_table("mutable_identity") { |table| table.generated_id("id") }
    @version = 999_i64
    @name = "mutated"
  end
end

private class RunnerSpecListener
  include LF::Data::Listener

  getter transaction_begins = 0
  getter transaction_outcomes = [] of LF::Data::TransactionOutcome
  getter statements = [] of LF::Data::StatementCompletionEvent

  def on_transaction_begin(event : LF::Data::TransactionBeginEvent) : Nil
    @transaction_begins += 1
  end

  def on_transaction_completion(event : LF::Data::TransactionCompletionEvent) : Nil
    @transaction_outcomes << event.outcome
  end

  def on_statement_completion(event : LF::Data::StatementCompletionEvent) : Nil
    @statements << event
  end
end

describe LF::Data::MigrationRunner do
  it "runs a fresh migration and records it" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )
      migration = RunnerSpecMigration.new(10_i64, "create_todos") do |schema|
        schema.create_table("todos") do |table|
          table.generated_id("id")
          table.string("title", null: false)
        end
      end

      LF::Data::MigrationRunner.new(source).run(
        LF::Data::MigrationSet.new(migration)
      )

      migration.runs.should eq(1)
      LF::DataSpecSupport::SQLiteDatabase.assert_table_exists!(database, "todos")
      database.query_one(
        "SELECT version, name FROM _lf_migrations"
      ) do |result|
        {result.read(Int64), result.read(String)}
      end.should eq({10_i64, "create_todos"})
    end
  end

  it "reports history and migration work through datasource listeners" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      listener = RunnerSpecListener.new
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new,
        listeners: [listener] of LF::Data::Listener
      )
      migration = RunnerSpecMigration.new(10_i64, "create_todos") do |schema|
        schema.create_table("todos") { |table| table.generated_id("id") }
      end

      LF::Data::MigrationRunner.new(source).run(
        LF::Data::MigrationSet.new(migration)
      )

      listener.transaction_begins.should eq(2)
      listener.transaction_outcomes.should eq([
        LF::Data::TransactionOutcome::Committed,
        LF::Data::TransactionOutcome::Committed,
      ])
      listener.statements.map(&.operation).should eq([
        LF::Data::StatementOperation::Schema,
        LF::Data::StatementOperation::Select,
        LF::Data::StatementOperation::Schema,
        LF::Data::StatementOperation::Insert,
      ])
      listener.statements.map(&.entity_name).should eq([
        "_lf_migrations",
        "_lf_migrations",
        "todos",
        "_lf_migrations",
      ])
    end
  end

  it "does not run an already applied migration again" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )
      migration = RunnerSpecMigration.new(10_i64, "create_todos") do |schema|
        schema.create_table("todos") { |table| table.generated_id("id") }
      end
      migrations = LF::Data::MigrationSet.new(migration)
      runner = LF::Data::MigrationRunner.new(source)

      2.times { runner.run(migrations) }

      migration.runs.should eq(1)
      database.scalar("SELECT count(*) FROM _lf_migrations").should eq(1_i64)
    end
  end

  it "records the validated migration identity snapshot" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )
      migration = MutableIdentityMigration.new(10_i64, "original")

      LF::Data::MigrationRunner.new(source).run(
        LF::Data::MigrationSet.new(migration)
      )

      database.query_one(
        "SELECT version, name FROM _lf_migrations"
      ) do |result|
        {result.read(Int64), result.read(String)}
      end.should eq({10_i64, "original"})
    end
  end

  it "runs multiple pending migrations in version order" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )
      execution_order = [] of Int64
      first = RunnerSpecMigration.new(10_i64, "first") do |schema|
        execution_order << 10_i64
        schema.create_table("first_table") { |table| table.generated_id("id") }
      end
      second = RunnerSpecMigration.new(20_i64, "second") do |schema|
        execution_order << 20_i64
        schema.create_table("second_table") { |table| table.generated_id("id") }
      end

      LF::Data::MigrationRunner.new(source).run(
        LF::Data::MigrationSet.new(first, second)
      )

      execution_order.should eq([10_i64, 20_i64])
      database.query_all(
        "SELECT version FROM _lf_migrations ORDER BY version",
        as: Int64
      ).should eq([10_i64, 20_i64])
    end
  end

  it "creates empty history for an empty migration set" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )

      LF::Data::MigrationRunner.new(source).run(LF::Data::MigrationSet.new)

      LF::DataSpecSupport::SQLiteDatabase.assert_table_exists!(
        database,
        "_lf_migrations"
      )
      database.scalar("SELECT count(*) FROM _lf_migrations").should eq(0_i64)
    end
  end

  it "validates the migration set before opening a datasource transaction" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      listener = RunnerSpecListener.new
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new,
        listeners: [listener] of LF::Data::Listener
      )
      migration = RunnerSpecMigration.new(10_i64, "mutable") { |_schema| }
      migrations = LF::Data::MigrationSet.new(migration)
      migration.version = 0_i64

      expect_raises(LF::Data::MigrationError) do
        LF::Data::MigrationRunner.new(source).run(migrations)
      end

      listener.transaction_begins.should eq(0)
    end
  end

  it "stops on failure and rolls back only the failing pending migration" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )
      first = RunnerSpecMigration.new(10_i64, "first") do |schema|
        schema.create_table("first_table") { |table| table.generated_id("id") }
      end
      failure = RunnerSpecFailure.new("second failed")
      second = RunnerSpecMigration.new(20_i64, "second") do |schema|
        schema.create_table("second_table") { |table| table.generated_id("id") }
        raise failure
      end
      third = RunnerSpecMigration.new(30_i64, "third") do |schema|
        schema.create_table("third_table") { |table| table.generated_id("id") }
      end

      error = expect_raises(RunnerSpecFailure) do
        LF::Data::MigrationRunner.new(source).run(
          LF::Data::MigrationSet.new(first, second, third)
        )
      end

      error.should be(failure)
      LF::DataSpecSupport::SQLiteDatabase.assert_table_exists!(database, "first_table")
      LF::DataSpecSupport::SQLiteDatabase.assert_table_missing!(database, "second_table")
      LF::DataSpecSupport::SQLiteDatabase.assert_table_missing!(database, "third_table")
      database.query_all(
        "SELECT version FROM _lf_migrations ORDER BY version",
        as: Int64
      ).should eq([10_i64])
      third.runs.should eq(0)
    end
  end

  it "rolls back migration SQL when its history insert fails" do
    database = DB.open("sqlite3://%3Amemory%3A")
    begin
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )
      runner = LF::Data::MigrationRunner.new(source)
      runner.run(LF::Data::MigrationSet.new)
      migration = RunnerSpecMigration.new(10_i64, "create_todos") do |schema|
        schema.create_table("todos") { |table| table.generated_id("id") }
        schema.raw(
          "claim_history",
          "INSERT INTO _lf_migrations (version, name, applied_at) " \
          "VALUES (10, 'conflict', '2026-08-04T12:00:00Z')"
        )
      end

      error = expect_raises(SQLite3::Exception) do
        runner.run(LF::Data::MigrationSet.new(migration))
      end

      error.message.to_s.should contain("UNIQUE constraint failed")
      LF::DataSpecSupport::SQLiteDatabase.assert_table_missing!(database, "todos")
      database.scalar("SELECT count(*) FROM _lf_migrations").should eq(0_i64)
    ensure
      begin
        database.close
      rescue SQLite3::Exception
        # sqlite3 repeats a cached failed statement error while finalizing the pool.
      end
    end
  end

  it "rolls back when a migration raises before executing SQL" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      listener = RunnerSpecListener.new
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new,
        listeners: [listener] of LF::Data::Listener
      )
      failure = RunnerSpecFailure.new("failed before SQL")
      migration = RunnerSpecMigration.new(10_i64, "fails_early") do |_schema|
        raise failure
      end

      error = expect_raises(RunnerSpecFailure) do
        LF::Data::MigrationRunner.new(source).run(
          LF::Data::MigrationSet.new(migration)
        )
      end

      error.should be(failure)
      listener.transaction_outcomes.should eq([
        LF::Data::TransactionOutcome::Committed,
        LF::Data::TransactionOutcome::RolledBack,
      ])
      listener.statements.map(&.operation).should eq([
        LF::Data::StatementOperation::Schema,
        LF::Data::StatementOperation::Select,
      ])
      database.scalar("SELECT count(*) FROM _lf_migrations").should eq(0_i64)
    end
  end

  it "preserves a database error raised by migration SQL" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      listener = RunnerSpecListener.new
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new,
        listeners: [listener] of LF::Data::Listener
      )
      migration = RunnerSpecMigration.new(10_i64, "bad_sql") do |schema|
        schema.drop_table("missing_table")
      end

      error = expect_raises(SQLite3::Exception) do
        LF::Data::MigrationRunner.new(source).run(
          LF::Data::MigrationSet.new(migration)
        )
      end

      error.should_not be_a(LF::Data::Error)
      listener.statements.last.operation.should eq(LF::Data::StatementOperation::Schema)
      listener.statements.last.error.should be(error)
      database.scalar("SELECT count(*) FROM _lf_migrations").should eq(0_i64)
    end
  end

  it "rejects an applied migration renamed in the current set before up" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )
      original = RunnerSpecMigration.new(10_i64, "original") do |schema|
        schema.create_table("todos") { |table| table.generated_id("id") }
      end
      runner = LF::Data::MigrationRunner.new(source)
      runner.run(LF::Data::MigrationSet.new(original))
      renamed = RunnerSpecMigration.new(10_i64, "renamed") { |_schema| }

      error = expect_raises(LF::Data::MigrationHistoryMismatchError) do
        runner.run(LF::Data::MigrationSet.new(renamed))
      end

      error.version.should eq(10_i64)
      error.applied_name.should eq("original")
      renamed.runs.should eq(0)
    end
  end
end
