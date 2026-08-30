require "spec"
require "pg"
require "../src/opal/data"
require "../src/opal/data/dialects/postgresql"

POSTGRESQL_URL = ENV["OPAL_POSTGRESQL_URL"]? || raise(
  "OPAL_POSTGRESQL_URL is required for PostgreSQL integration specs"
)

@[LF::Data::Table("opal_pg_projects")]
private class PostgreSQLIntegrationProject
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  property name : String
  property active : Bool
  getter created_at : Time
  getter payload : Bytes

  @[LF::Data::Version]
  getter version : Int64 = 0_i64

  def initialize(
    @name : String,
    @active : Bool,
    @created_at : Time,
    @payload : Bytes,
  )
    @id = nil
  end
end

private class CreatePostgreSQLProjects < LF::Data::Migration
  def version : Int64
    10_i64
  end

  def name : String
    "create_postgresql_projects"
  end

  def up(schema : LF::Data::SchemaEditor) : Nil
    schema.create_table("opal_pg_projects") do |table|
      table.generated_id("id")
      table.string("name", null: false)
      table.bool("active", null: false, default: false)
      table.timestamp("created_at", null: false)
      table.bytes("payload", null: false)
      table.int64("version", null: false, default: 0_i64)
      table.index("idx_opal_pg_projects_active", "active")
    end
  end
end

private class BlockingPostgreSQLMigration < LF::Data::Migration
  def initialize(
    @entered : Channel(Nil),
    @release : Channel(Nil),
  )
  end

  def version : Int64
    20_i64
  end

  def name : String
    "postgresql_lock_serialization"
  end

  def up(schema : LF::Data::SchemaEditor) : Nil
    @entered.send(nil)
    @release.receive
    schema.raw(
      "postgresql_lock_effect",
      "INSERT INTO opal_pg_lock_effects (value) VALUES ('applied')"
    )
  end
end

private class UnexpectedPostgreSQLMigration < LF::Data::Migration
  def initialize(@entered : Channel(Nil))
  end

  def version : Int64
    20_i64
  end

  def name : String
    "postgresql_lock_serialization"
  end

  def up(schema : LF::Data::SchemaEditor) : Nil
    @entered.send(nil)
    schema.raw(
      "unexpected_postgresql_lock_effect",
      "INSERT INTO opal_pg_lock_effects (value) VALUES ('unexpected')"
    )
  end
end

private class FailingPostgreSQLMigration < LF::Data::Migration
  def version : Int64
    30_i64
  end

  def name : String
    "postgresql_lock_failure"
  end

  def up(schema : LF::Data::SchemaEditor) : Nil
    raise "postgresql migration failed"
  end
end

private class SuccessfulPostgreSQLMigration < LF::Data::Migration
  def version : Int64
    30_i64
  end

  def name : String
    "postgresql_lock_failure"
  end

  def up(schema : LF::Data::SchemaEditor) : Nil
    schema.raw(
      "postgresql_failure_recovery",
      "INSERT INTO opal_pg_lock_effects (value) VALUES ('recovered')"
    )
  end
end

private def reset_postgresql_integration : Nil
  DB.open(POSTGRESQL_URL) do |database|
    database.exec("DROP TABLE IF EXISTS opal_pg_projects CASCADE")
    database.exec("DROP TABLE IF EXISTS opal_pg_lock_effects CASCADE")
    database.exec("DROP TABLE IF EXISTS _lf_migrations CASCADE")
  end
end

private def postgresql_source : LF::Data::DataSource
  LF::Data::DataSource.open(
    POSTGRESQL_URL,
    dialect: LF::Data::Dialects::PostgreSQL.new(
      lock_poll_interval: 10.milliseconds
    )
  )
end

describe "PostgreSQL Data integration" do
  before_each { reset_postgresql_integration }
  after_each { reset_postgresql_integration }

  it "runs migrations and generated CRUD through RETURNING" do
    source = nil.as(LF::Data::DataSource?)
    source = postgresql_source
    migrations = LF::Data::MigrationSet.new(CreatePostgreSQLProjects.new)
    runner = LF::Data::MigrationRunner.new(
      source,
      lock_namespace: "opal-integration-crud",
      lock_timeout: 2.seconds
    )

    2.times { runner.run(migrations) }
    created_at = Time.utc(2026, 8, 30, 12, 45, 0)
    project = source.transaction do |manager|
      entity = PostgreSQLIntegrationProject.new(
        "postgresql",
        true,
        created_at,
        Bytes[0x0a, 0xff]
      )
      manager.persist(entity)
      manager.flush
      entity
    end

    project.id.should_not be_nil
    project.version.should eq(0_i64)

    updated = source.transaction do |manager|
      entity = manager.find(
        PostgreSQLIntegrationProject,
        project.id.not_nil!
      ).not_nil!
      entity.name = "postgresql-ready"
      manager.persist(entity)
      entity
    end
    updated.version.should eq(1_i64)

    source.transaction do |manager|
      loaded = manager.find(
        PostgreSQLIntegrationProject,
        project.id.not_nil!
      ).not_nil!
      loaded.name.should eq("postgresql-ready")
      loaded.active.should be_true
      loaded.created_at.should eq(created_at)
      loaded.payload.should eq(Bytes[0x0a, 0xff])
      manager.connection.scalar(
        "SELECT count(*) FROM _lf_migrations WHERE version = $1",
        10_i64
      ).should eq(1_i64)
      manager.connection.query_one(
        "SELECT applied_at FROM _lf_migrations WHERE version = $1",
        10_i64,
        as: Time
      ).should be_a(Time)
    end
  ensure
    source.try &.close
  end

  it "serializes concurrent runners before migration planning" do
    setup = nil.as(DB::Database?)
    first_source = nil.as(LF::Data::DataSource?)
    second_source = nil.as(LF::Data::DataSource?)
    setup = DB.open(POSTGRESQL_URL)
    setup.exec(
      "CREATE TABLE opal_pg_lock_effects " \
      "(id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, value TEXT NOT NULL)"
    )
    setup.close
    first_source = postgresql_source
    second_source = postgresql_source
    entered = Channel(Nil).new(1)
    release = Channel(Nil).new(1)
    unexpected = Channel(Nil).new(1)
    done = Channel(Exception?).new(2)

    spawn do
      begin
        LF::Data::MigrationRunner.new(
          first_source,
          lock_namespace: "opal-integration-concurrency",
          lock_timeout: 2.seconds
        ).run(
          LF::Data::MigrationSet.new(
            BlockingPostgreSQLMigration.new(entered, release)
          )
        )
        done.send(nil)
      rescue error
        done.send(error)
      end
    end
    select
    when entered.receive
    when timeout(5.seconds)
      fail "first PostgreSQL migration did not reach the barrier"
    end

    spawn do
      begin
        LF::Data::MigrationRunner.new(
          second_source,
          lock_namespace: "opal-integration-concurrency",
          lock_timeout: 2.seconds
        ).run(
          LF::Data::MigrationSet.new(
            UnexpectedPostgreSQLMigration.new(unexpected)
          )
        )
        done.send(nil)
      rescue error
        done.send(error)
      end
    end

    select
    when unexpected.receive
      fail "second PostgreSQL migration ran before the advisory lock released"
    when timeout(150.milliseconds)
    end
    release.send(nil)
    2.times do
      select
      when result = done.receive
        result.should be_nil
      when timeout(5.seconds)
        fail "PostgreSQL migration runner did not finish"
      end
    end

    DB.open(POSTGRESQL_URL) do |verification|
      verification.scalar("SELECT count(*) FROM opal_pg_lock_effects")
        .should eq(1_i64)
      verification.scalar(
        "SELECT count(*) FROM _lf_migrations WHERE version = $1",
        20_i64
      ).should eq(1_i64)
    end
  ensure
    first_source.try &.close
    second_source.try &.close
    setup.try &.close
  end

  it "times out predictably and releases the lock after migration failure" do
    setup = nil.as(DB::Database?)
    holder_database = nil.as(DB::Database?)
    source = nil.as(LF::Data::DataSource?)
    failing_source = nil.as(LF::Data::DataSource?)
    recovery_source = nil.as(LF::Data::DataSource?)
    setup = DB.open(POSTGRESQL_URL)
    setup.exec(
      "CREATE TABLE opal_pg_lock_effects " \
      "(id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, value TEXT NOT NULL)"
    )
    setup.close
    holder_database = DB.open(POSTGRESQL_URL)
    holder_database.using_connection do |connection|
      dialect = LF::Data::Dialects::PostgreSQL.new(
        lock_poll_interval: 10.milliseconds
      )
      holder = dialect.migration_lock(
        connection,
        "opal-integration-timeout",
        1.second
      ).as(LF::Data::Dialects::PostgreSQL::AdvisoryMigrationLock)
      begin
        holder.acquire
        holder.acquire

        source = postgresql_source
        expect_raises(LF::Data::MigrationLockTimeoutError) do
          LF::Data::MigrationRunner.new(
            source,
            lock_namespace: "opal-integration-timeout",
            lock_timeout: 100.milliseconds
          ).run(LF::Data::MigrationSet.new)
        end
      ensure
        source.try &.close
        holder.release
        holder.release
      end
    end
    holder_database.close

    failing_source = postgresql_source
    expect_raises(Exception, "postgresql migration failed") do
      LF::Data::MigrationRunner.new(
        failing_source,
        lock_namespace: "opal-integration-failure",
        lock_timeout: 1.second
      ).run(
        LF::Data::MigrationSet.new(FailingPostgreSQLMigration.new)
      )
    end
    failing_source.close

    recovery_source = postgresql_source
    LF::Data::MigrationRunner.new(
      recovery_source,
      lock_namespace: "opal-integration-failure",
      lock_timeout: 1.second
    ).run(
      LF::Data::MigrationSet.new(SuccessfulPostgreSQLMigration.new)
    )
    recovery_source.transaction do |manager|
      manager.connection.scalar(
        "SELECT count(*) FROM opal_pg_lock_effects WHERE value = $1",
        "recovered"
      ).should eq(1_i64)
    end
  ensure
    source.try &.close
    failing_source.try &.close
    recovery_source.try &.close
    holder_database.try &.close
    setup.try &.close
  end
end
