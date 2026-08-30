require "./spec_helper"
require "../../src/opal/data/dialects/sqlite"
require "./support/sqlite_database"

private class RunnerLockProbe < LF::Data::MigrationLock
  getter acquire_calls = 0
  getter release_calls = 0
  property acquire_error : Exception?
  property release_error : Exception?

  def acquire : Nil
    @acquire_calls += 1
    if failure = acquire_error
      raise failure
    end
  end

  def release : Nil
    @release_calls += 1
    if failure = release_error
      raise failure
    end
  end
end

private class RunnerLockDialect < LF::Data::Dialects::SQLite
  getter lock = RunnerLockProbe.new
  getter lock_connection_id : UInt64?
  getter schema_connection_ids = [] of UInt64
  property? lock_supported = true
  property? transactional_ddl_supported = true

  def migration_lock(
    connection : DB::Connection,
    namespace : String,
    timeout : Time::Span,
  ) : LF::Data::MigrationLock
    @lock_connection_id = connection.object_id
    namespace.should eq("opal-spec")
    timeout.should eq(250.milliseconds)
    lock
  end

  def schema_renderer(connection : DB::Connection) : LF::Data::SchemaRenderer
    @schema_connection_ids << connection.object_id
    super
  end

  def supports?(capability : LF::Data::DialectCapability) : Bool
    return lock_supported? if capability.migration_lock?
    return transactional_ddl_supported? if capability.transactional_ddl?
    super
  end
end

private class RunnerLockMigration < LF::Data::Migration
  getter version : Int64
  getter name : String

  def initialize(
    @version : Int64,
    @name : String,
    &@action : LF::Data::SchemaEditor -> Nil
  )
  end

  def up(schema : LF::Data::SchemaEditor) : Nil
    @action.call(schema)
  end
end

describe "migration runner lock session" do
  it "fails before history SQL when the dialect has no safe migration lock" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      dialect = RunnerLockDialect.new
      dialect.lock_supported = false
      source = LF::Data::DataSource.new(database, dialect: dialect)

      error = expect_raises(LF::Data::UnsupportedMigrationCapabilityError) do
        LF::Data::MigrationRunner.new(source).run(LF::Data::MigrationSet.new)
      end

      error.capability.should eq(LF::Data::DialectCapability::MigrationLock)
      database.scalar(
        "SELECT count(*) FROM sqlite_master " \
        "WHERE type = 'table' AND name = '_lf_migrations'"
      ).should eq(0_i64)
    end
  end

  it "fails before history SQL when transactional DDL is unavailable" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      dialect = RunnerLockDialect.new
      dialect.transactional_ddl_supported = false
      source = LF::Data::DataSource.new(database, dialect: dialect)

      error = expect_raises(LF::Data::UnsupportedMigrationCapabilityError) do
        LF::Data::MigrationRunner.new(source).run(LF::Data::MigrationSet.new)
      end

      error.capability.should eq(LF::Data::DialectCapability::TransactionalDDL)
      dialect.lock.acquire_calls.should eq(0)
      database.scalar(
        "SELECT count(*) FROM sqlite_master " \
        "WHERE type = 'table' AND name = '_lf_migrations'"
      ).should eq(0_i64)
    end
  end

  it "pins lock, planning, and every migration to one connection" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      dialect = RunnerLockDialect.new
      source = LF::Data::DataSource.new(database, dialect: dialect)
      first = RunnerLockMigration.new(10_i64, "first") do |schema|
        schema.create_table("first_locked") { |table| table.generated_id("id") }
      end
      second = RunnerLockMigration.new(20_i64, "second") do |schema|
        schema.create_table("second_locked") { |table| table.generated_id("id") }
      end

      LF::Data::MigrationRunner.new(
        source,
        lock_namespace: "opal-spec",
        lock_timeout: 250.milliseconds
      ).run(LF::Data::MigrationSet.new(first, second))

      dialect.lock.acquire_calls.should eq(1)
      dialect.lock.release_calls.should eq(1)
      dialect.lock_connection_id.should_not be_nil
      dialect.schema_connection_ids.should_not be_empty
      dialect.schema_connection_ids.uniq.should eq([
        dialect.lock_connection_id.not_nil!,
      ])
    end
  end

  it "releases the lock when a migration fails" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      dialect = RunnerLockDialect.new
      source = LF::Data::DataSource.new(database, dialect: dialect)
      failure = Exception.new("migration failed")
      migration = RunnerLockMigration.new(10_i64, "failure") do |_schema|
        raise failure
      end

      raised = expect_raises(Exception) do
        LF::Data::MigrationRunner.new(
          source,
          lock_namespace: "opal-spec",
          lock_timeout: 250.milliseconds
        ).run(LF::Data::MigrationSet.new(migration))
      end

      raised.should be(failure)
      dialect.lock.acquire_calls.should eq(1)
      dialect.lock.release_calls.should eq(1)
    end
  end

  it "attempts release when lock acquisition fails" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      dialect = RunnerLockDialect.new
      source = LF::Data::DataSource.new(database, dialect: dialect)
      failure = Exception.new("lock acquisition failed")
      dialect.lock.acquire_error = failure

      raised = expect_raises(Exception) do
        LF::Data::MigrationRunner.new(
          source,
          lock_namespace: "opal-spec",
          lock_timeout: 250.milliseconds
        ).run(LF::Data::MigrationSet.new)
      end

      raised.should be(failure)
      dialect.lock.acquire_calls.should eq(1)
      dialect.lock.release_calls.should eq(1)
    end
  end

  it "rejects invalid lock configuration before datasource work" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      source = LF::Data::DataSource.new(
        database,
        dialect: RunnerLockDialect.new
      )

      expect_raises(LF::Data::MigrationLockConfigurationError) do
        LF::Data::MigrationRunner.new(source, lock_namespace: "")
      end
      expect_raises(LF::Data::MigrationLockConfigurationError) do
        LF::Data::MigrationRunner.new(
          source,
          lock_timeout: -1.millisecond
        )
      end
      database.scalar(
        "SELECT count(*) FROM sqlite_master " \
        "WHERE type = 'table' AND name = '_lf_migrations'"
      ).should eq(0_i64)
    end
  end

  it "preserves migration and lock cleanup failures together" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      dialect = RunnerLockDialect.new
      source = LF::Data::DataSource.new(database, dialect: dialect)
      migration_failure = Exception.new("migration failed")
      release_failure = Exception.new("unlock failed")
      dialect.lock.release_error = release_failure
      migration = RunnerLockMigration.new(10_i64, "failure") do |_schema|
        raise migration_failure
      end

      error = expect_raises(LF::Data::MigrationLockCleanupError) do
        LF::Data::MigrationRunner.new(
          source,
          lock_namespace: "opal-spec",
          lock_timeout: 250.milliseconds
        ).run(LF::Data::MigrationSet.new(migration))
      end

      error.primary_error.should be(migration_failure)
      error.cleanup_error.should be(release_failure)
      error.cause.should be(migration_failure)
    end
  end
end
