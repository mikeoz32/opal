require "./spec_helper"
require "../../src/opal/data/dialects/sqlite"
require "./support/sqlite_database"

private class ConcurrentRunnerMigration < LF::Data::Migration
  def initialize(
    @ready : Channel(Nil),
    @release : Channel(Nil),
  )
  end

  def version : Int64
    10_i64
  end

  def name : String
    "concurrent_insert"
  end

  def up(schema : LF::Data::SchemaEditor) : Nil
    @ready.send(nil)
    @release.receive
    schema.raw(
      "insert_migration_effect",
      "INSERT INTO migration_effects (value) VALUES ('applied')"
    )
  end
end

private class ConcurrentFailureMigration < LF::Data::Migration
  def initialize(
    @ready : Channel(Nil),
    @release : Channel(Nil),
    @failure : Exception,
  )
  end

  def version : Int64
    20_i64
  end

  def name : String
    "concurrent_failure"
  end

  def up(schema : LF::Data::SchemaEditor) : Nil
    @ready.send(nil)
    @release.receive
    raise @failure
  end
end

private class ConcurrentSuccessMigration < LF::Data::Migration
  def version : Int64
    20_i64
  end

  def name : String
    "concurrent_failure"
  end

  def up(schema : LF::Data::SchemaEditor) : Nil
    schema.raw(
      "insert_failure_effect",
      "INSERT INTO failure_effects (value) VALUES ('applied')"
    )
  end
end

describe "concurrent migration runners" do
  it "uses transactional history uniqueness to prevent a double application" do
    path = LF::DataSpecSupport::TempPath.database
    url = "sqlite3:#{path}?busy_timeout=5000"
    first_database = DB.open(url)
    second_database = DB.open(url)
    first_source = LF::Data::DataSource.new(
      first_database,
      dialect: LF::Data::Dialects::SQLite.new
    )
    second_source = LF::Data::DataSource.new(
      second_database,
      dialect: LF::Data::Dialects::SQLite.new
    )
    first_database.exec(
      "CREATE TABLE migration_effects " \
      "(id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT NOT NULL)"
    )
    LF::Data::MigrationRunner.new(first_source).run(LF::Data::MigrationSet.new)
    ready = Channel(Nil).new(2)
    release = Channel(Nil).new(2)
    done = Channel(Exception?).new(2)

    [first_source, second_source].each do |source|
      spawn do
        begin
          migration = ConcurrentRunnerMigration.new(ready, release)
          LF::Data::MigrationRunner.new(source).run(
            LF::Data::MigrationSet.new(migration)
          )
          done.send(nil)
        rescue error
          done.send(error)
        end
      end
    end

    2.times do
      select
      when ready.receive
      when timeout(5.seconds)
        raise "Concurrent migration runner did not reach the barrier"
      end
    end
    2.times { release.send(nil) }
    results = 2.times.map do
      select
      when result = done.receive
        result
      when timeout(5.seconds)
        raise "Concurrent migration runner did not finish"
      end
    end.to_a

    results.count(&.nil?).should eq(2)
    results.compact.should be_empty

    DB.open(url) do |verification_database|
      verification_database.scalar(
        "SELECT count(*) FROM migration_effects"
      ).should eq(1_i64)
      verification_database.scalar(
        "SELECT count(*) FROM _lf_migrations WHERE version = 10"
      ).should eq(1_i64)
    end
  ensure
    first_source.try &.close
    second_source.try &.close
    [first_database, second_database].each do |database|
      begin
        database.try &.close
      rescue SQLite3::Exception
        # sqlite3 repeats a cached failed statement error while finalizing the pool.
      end
    end
    LF::DataSpecSupport::TempPath.cleanup_database(path) if path
  end

  it "does not reconcile an unrelated migration failure after another runner commits" do
    path = LF::DataSpecSupport::TempPath.database
    url = "sqlite3:#{path}?busy_timeout=5000"
    first_database = DB.open(url)
    second_database = DB.open(url)
    first_source = LF::Data::DataSource.new(
      first_database,
      dialect: LF::Data::Dialects::SQLite.new
    )
    second_source = LF::Data::DataSource.new(
      second_database,
      dialect: LF::Data::Dialects::SQLite.new
    )
    first_database.exec(
      "CREATE TABLE failure_effects " \
      "(id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT NOT NULL)"
    )
    LF::Data::MigrationRunner.new(first_source).run(LF::Data::MigrationSet.new)
    ready = Channel(Nil).new(1)
    release = Channel(Nil).new(1)
    done = Channel(Exception?).new(1)
    failure = Exception.new("unrelated failure")

    spawn do
      begin
        migration = ConcurrentFailureMigration.new(ready, release, failure)
        LF::Data::MigrationRunner.new(first_source).run(
          LF::Data::MigrationSet.new(migration)
        )
        done.send(nil)
      rescue error
        done.send(error)
      end
    end

    select
    when ready.receive
    when timeout(5.seconds)
      raise "Concurrent migration failure runner did not reach the barrier"
    end

    success_migration = ConcurrentSuccessMigration.new
    LF::Data::MigrationRunner.new(second_source).run(
      LF::Data::MigrationSet.new(success_migration)
    )
    release.send(nil)

    result = select
    when value = done.receive
      value
    when timeout(5.seconds)
      raise "Concurrent migration failure runner did not finish"
    end

    result.should be(failure)
    DB.open(url) do |verification_database|
      verification_database.scalar(
        "SELECT count(*) FROM _lf_migrations WHERE version = 20"
      ).should eq(1_i64)
    end
  ensure
    first_source.try &.close
    second_source.try &.close
    [first_database, second_database].each do |database|
      begin
        database.try &.close
      rescue SQLite3::Exception
        # sqlite3 repeats a cached failed statement error while finalizing the pool.
      end
    end
    LF::DataSpecSupport::TempPath.cleanup_database(path) if path
  end
end
