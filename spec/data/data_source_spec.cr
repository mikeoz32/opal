require "./spec_helper"
require "../../src/opal/data"
require "../../src/opal/data/dialects/sqlite"
require "./support/sqlite_database"
require "./support/probe_entity_manager"

private class TransactionResultProbe
end

private class DataSourceListenerProbe
  include LF::Data::Listener

  getter events = [] of String
  property raise_on : Symbol?

  def on_transaction_begin(event : LF::Data::TransactionBeginEvent) : Nil
    @events << "begin"
    raise "listener begin failed" if @raise_on == :begin
  end

  def on_transaction_completion(event : LF::Data::TransactionCompletionEvent) : Nil
    @events << "transaction:#{event.outcome}"
    raise "listener completion failed" if @raise_on == :transaction_completion
  end

  def on_statement_completion(event : LF::Data::StatementCompletionEvent) : Nil
    @events << "statement:#{event.operation}"
    raise "listener statement failed" if @raise_on == :statement_completion
  end
end

private class FailingSetupSQLiteDialect < LF::Data::Dialects::SQLite
  def setup_connection(connection : DB::Connection) : Nil
    raise "connection setup failed"
  end
end

@[LF::Data::Table("datasource_entities")]
private class DataSourceEntity
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  getter value : String

  def initialize(@value : String)
    @id = nil
  end
end

describe LF::Data::DataSource do
  it "closes an owned database when initial connection setup fails" do
    expect_raises(Exception, "connection setup failed") do
      LF::Data::DataSource.open(
        "sqlite3://%3Amemory%3A",
        dialect: FailingSetupSQLiteDialect.new
      )
    end
  end

  it "enables SQLite foreign-key enforcement on every connection" do
    database = DB.open("sqlite3://%3Amemory%3A")
    begin
      database.exec("CREATE TABLE fk_parents (id INTEGER PRIMARY KEY)")
      database.exec(
        "CREATE TABLE fk_children " \
        "(parent_id INTEGER NOT NULL REFERENCES fk_parents(id))"
      )
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )

      source.transaction { nil }
      database.scalar("PRAGMA foreign_keys").should eq(1_i64)
      expect_raises(SQLite3::Exception) do
        source.transaction do |manager|
          manager.connection.exec(
            "INSERT INTO fk_children (parent_id) VALUES (?)",
            999_i64
          )
        end
      end
    ensure
      source.try &.close
      begin
        database.close
      rescue SQLite3::Exception
        # sqlite3 can repeat the failed foreign-key statement while closing.
      end
    end
  end

  it "borrows an injected database by default" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )

      source.close

      database.scalar("SELECT 1").should eq(1_i64)
    end
  end

  it "closes pooled connections when database ownership is explicit" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new,
        owns_database: true
      )
      database.pool.stats.open_connections.should eq(1)

      source.close

      database.pool.stats.open_connections.should eq(0)
      expect_raises(LF::Data::ClosedDataSourceError) do
        source.transaction { nil }
      end
    end
  end

  it "closes idempotently" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )

      source.close
      source.close

      source.closed?.should be_true
      database.scalar("SELECT 1").should eq(1_i64)
    end
  end

  it "owns databases created through open" do
    source = LF::Data::DataSource.open(
      "sqlite3://%3Amemory%3A",
      dialect: LF::Data::Dialects::SQLite.new
    )

    source.owns_database?.should be_true
    source.transaction { "available" }.should eq("available")
    source.close
    source.closed?.should be_true
  ensure
    source.try &.close
  end

  it "returns the exact transaction block result" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )
      result = TransactionResultProbe.new

      returned = source.transaction { |_manager| result }

      returned.should be(result)
    ensure
      source.try &.close
    end
  end

  it "provides a connection-scoped read without opening a transaction" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.exec(
        "CREATE TABLE datasource_entities " \
        "(id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT NOT NULL)"
      )
      database.exec("INSERT INTO datasource_entities (value) VALUES (?)", "read-only")
      listener = DataSourceListenerProbe.new
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new,
        listeners: [listener] of LF::Data::Listener
      )

      values = source.read do |manager|
        manager.query(DataSourceEntity).to_a.map(&.value)
      end

      values.should eq(["read-only"])
      listener.events.should eq(["statement:Select"])
    ensure
      source.try &.close
    end
  end

  it "rejects mutations in a read scope" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.exec(
        "CREATE TABLE datasource_entities " \
        "(id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT NOT NULL)"
      )
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )

      error = expect_raises(LF::Data::ReadOnlyEntityManagerError) do
        source.read do |manager|
          manager.persist(DataSourceEntity.new("must not persist"))
        end
      end

      error.operation.should eq(:persist)
      database.scalar("SELECT count(*) FROM datasource_entities").should eq(0_i64)
    ensure
      source.try &.close
    end
  end

  it "rejects every public write escape hatch in a read scope" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.exec(
        "CREATE TABLE datasource_entities " \
        "(id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT NOT NULL)"
      )
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )

      source.read do |manager|
        expect_raises(LF::Data::ReadOnlyEntityManagerError, /bulk_update/) do
          manager.update(DataSourceEntity)
        end
        expect_raises(LF::Data::ReadOnlyEntityManagerError, /bulk_delete/) do
          manager.delete(DataSourceEntity)
        end
        expect_raises(LF::Data::ReadOnlyEntityManagerError, /remove/) do
          manager.remove(DataSourceEntity.new("must not remove"))
        end
        expect_raises(LF::Data::ReadOnlyEntityManagerError, /flush/) do
          manager.flush
        end
        expect_raises(LF::Data::ReadOnlyEntityManagerError, /connection/) do
          manager.connection
        end
      end
    ensure
      source.try &.close
    end
  end

  it "returns nil without confusing it with an explicit rollback" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )

      source.transaction { nil }.should be_nil
    ensure
      source.try &.close
    end
  end

  it "yields an EntityManager with the datasource dialect" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      dialect : LF::Data::Dialect = LF::Data::Dialects::SQLite.new
      source = LF::DataSpecSupport::ProbeDataSource.new(
        database,
        dialect: dialect
      )

      source.transaction do |manager|
        manager.should be_a(LF::Data::EntityManager)
      end

      source.managers.one?.should be_true
      source.managers.first.dialect_id.should eq(dialect.object_id)
    ensure
      source.try &.close
    end
  end

  it "rejects transactions after close with a typed error" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )
      source.close

      error = expect_raises(LF::Data::ClosedDataSourceError) do
        source.transaction { nil }
      end

      error.operation.should eq(:transaction)
    end
  end

  it "flushes, commits, and closes before returning the connection to the pool" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.exec("CREATE TABLE transaction_order (value TEXT NOT NULL)")
      source = LF::DataSpecSupport::ProbeDataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )
      close_observation = nil.as({Bool, Int32}?)
      source.flush_hook = ->(manager : LF::DataSpecSupport::ProbeEntityManager) {
        manager.exec("INSERT INTO transaction_order (value) VALUES (?)", "committed")
        nil
      }
      source.close_hook = ->(manager : LF::DataSpecSupport::ProbeEntityManager) {
        close_observation = {
          manager.transaction_available?,
          database.pool.stats.idle_connections,
        }
        nil
      }

      source.transaction { nil }

      source.managers.first.events.should eq([:flush, :close])
      close_observation.should eq({true, 0})
      database.pool.stats.in_flight_connections.should eq(0)
      database.pool.stats.idle_connections.should eq(1)
      database.scalar("SELECT count(*) FROM transaction_order").should eq(1_i64)
    ensure
      source.try &.close
    end
  end

  it "rolls back a block exception, skips flush, and propagates it unchanged" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.exec("CREATE TABLE block_rollback (value TEXT NOT NULL)")
      source = LF::DataSpecSupport::ProbeDataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )
      failure = Exception.new("application failed")

      raised = expect_raises(Exception) do
        source.transaction do |manager|
          manager.as(LF::DataSpecSupport::ProbeEntityManager)
            .exec("INSERT INTO block_rollback (value) VALUES (?)", "rolled back")
          raise failure
        end
      end

      raised.should be(failure)
      source.managers.first.events.should eq([:close])
      database.pool.stats.in_flight_connections.should eq(0)
      database.scalar("SELECT count(*) FROM block_rollback").should eq(0_i64)
    ensure
      source.try &.close
    end
  end

  it "does not wrap a driver exception in a framework error" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      source = LF::DataSpecSupport::ProbeDataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )

      error = expect_raises(Exception) do
        source.transaction do |manager|
          manager.as(LF::DataSpecSupport::ProbeEntityManager)
            .exec("SELECT * FROM table_that_does_not_exist WHERE ? IS NULL", nil)
        end
      end

      error.should_not be_a(LF::Data::Error)
      database.pool.stats.idle_connections.should eq(1)
    ensure
      source.try &.close
    end
  end

  it "rolls back a flush exception and propagates it unchanged" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.exec("CREATE TABLE flush_rollback (value TEXT NOT NULL)")
      source = LF::DataSpecSupport::ProbeDataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )
      failure = Exception.new("flush failed")
      source.flush_hook = ->(manager : LF::DataSpecSupport::ProbeEntityManager) {
        manager.exec("INSERT INTO flush_rollback (value) VALUES (?)", "rolled back")
        raise failure
      }

      raised = expect_raises(Exception) { source.transaction { nil } }

      raised.should be(failure)
      source.managers.first.events.should eq([:flush, :close])
      database.pool.stats.in_flight_connections.should eq(0)
      database.scalar("SELECT count(*) FROM flush_rollback").should eq(0_i64)
    ensure
      source.try &.close
    end
  end

  it "reports a committed transaction when manager cleanup fails after commit" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.exec("CREATE TABLE close_failure (value TEXT NOT NULL)")
      listener = DataSourceListenerProbe.new
      source = LF::DataSpecSupport::ProbeDataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new,
        listeners: [listener] of LF::Data::Listener
      )
      failure = Exception.new("close failed")
      source.flush_hook = ->(manager : LF::DataSpecSupport::ProbeEntityManager) {
        manager.exec("INSERT INTO close_failure (value) VALUES (?)", "committed")
        nil
      }
      source.close_hook = ->(_manager : LF::DataSpecSupport::ProbeEntityManager) {
        raise failure
      }

      raised = expect_raises(Exception) { source.transaction { nil } }

      raised.should be(failure)
      database.scalar("SELECT count(*) FROM close_failure").should eq(1_i64)
      listener.events.should eq(["begin", "transaction:Committed"])
    ensure
      source.try &.close
    end
  end

  it "propagates an explicit DB rollback unchanged after rollback completes" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      source = LF::DataSpecSupport::ProbeDataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )
      rollback = DB::Rollback.new("explicit rollback")

      raised = expect_raises(DB::Rollback) do
        source.transaction { raise rollback }
      end

      raised.should be(rollback)
      source.managers.first.events.should eq([:close])
      database.pool.stats.idle_connections.should eq(1)
    ensure
      source.try &.close
    end
  end

  it "reports committed and rolled back transactions without replacing errors" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      listener = DataSourceListenerProbe.new
      source = LF::DataSpecSupport::ProbeDataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new,
        listeners: [listener] of LF::Data::Listener
      )

      source.transaction { "committed" }
      failure = Exception.new("application failed")
      listener.raise_on = :transaction_completion
      raised = expect_raises(Exception) do
        source.transaction { raise failure }
      end

      raised.should be(failure)
      listener.events.should eq([
        "begin",
        "transaction:Committed",
        "begin",
        "transaction:RolledBack",
      ])
    ensure
      source.try &.close
    end
  end

  it "shares the datasource dispatcher with transaction managers" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      listener = DataSourceListenerProbe.new
      source = LF::DataSpecSupport::ProbeDataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new,
        listeners: [listener] of LF::Data::Listener
      )

      source.transaction do |manager|
        manager.as(LF::DataSpecSupport::ProbeEntityManager).emit_statement(
          LF::Data::StatementCompletionEvent.new(
            LF::Data::StatementOperation::Select,
            "Todo",
            "SELECT id FROM todos",
            Time::Span.zero,
            nil,
            nil
          )
        )
      end

      listener.events.should eq([
        "begin",
        "statement:Select",
        "transaction:Committed",
      ])
    ensure
      source.try &.close
    end
  end

  it "uses distinct manager and connection lifetimes for overlapping fibers" do
    database = DB.open(
      "sqlite3://%3Amemory%3A?initial_pool_size=0&max_pool_size=2&max_idle_pool_size=2"
    )
    source = LF::DataSpecSupport::ProbeDataSource.new(
      database,
      dialect: LF::Data::Dialects::SQLite.new
    )
    ready = Channel({UInt64, UInt64}).new(2)
    release = Channel(Nil).new
    done = Channel(Exception?).new(2)

    2.times do
      spawn do
        begin
          source.transaction do |manager|
            probe = manager.as(LF::DataSpecSupport::ProbeEntityManager)
            ready.send({probe.object_id, probe.connection_id})
            release.receive
          end
          done.send(nil)
        rescue error
          done.send(error)
        end
      end
    end

    first = ready.receive
    second = ready.receive
    first[0].should_not eq(second[0])
    first[1].should_not eq(second[1])

    2.times { release.send(nil) }
    2.times do
      error = done.receive
      raise error if error
    end

    source.managers.each(&.closed?.should(be_true))
    database.pool.stats.idle_connections.should eq(2)
  ensure
    source.try &.close
    database.try &.close
  end

  it "keeps repeated prepared SQL on the checked-out connection" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.exec("CREATE TABLE repeated_sql (value TEXT NOT NULL)")
      source = LF::DataSpecSupport::ProbeDataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )
      connection_ids = [] of UInt64

      source.transaction do |manager|
        probe = manager.as(LF::DataSpecSupport::ProbeEntityManager)
        2.times do |index|
          connection_ids << probe.connection_id
          probe.exec("INSERT INTO repeated_sql (value) VALUES (?)", index.to_s)
        end
      end

      connection_ids.uniq.size.should eq(1)
      database.scalar("SELECT count(*) FROM repeated_sql").should eq(2_i64)
    ensure
      source.try &.close
    end
  end

  it "does not own plan or prepared-statement caches" do
    data_source_source = File.read(
      File.expand_path("../../src/opal/data/data_source.cr", __DIR__)
    )
    manager_source = File.read(
      File.expand_path("../../src/opal/data/entity_manager.cr", __DIR__)
    )

    {data_source_source, manager_source}.each do |source|
      source.should_not contain("DB::Statement")
      source.should_not contain("PlanCache")
      source.should_not contain("@statement_cache")
      source.should_not contain("@plan_cache")
    end
  end

  it "automatically flushes entities after the transaction block returns" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.exec(
        "CREATE TABLE datasource_entities " \
        "(id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT NOT NULL)"
      )
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )
      entity = DataSourceEntity.new("automatic")

      source.transaction do |manager|
        manager.persist(entity)
        entity.id.should be_nil
      end

      entity.id.should_not be_nil
      database.scalar("SELECT value FROM datasource_entities")
        .should eq("automatic")
    end
  end

  it "skips queued writes when the transaction block fails" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.exec(
        "CREATE TABLE datasource_entities " \
        "(id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT NOT NULL)"
      )
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )
      entity = DataSourceEntity.new("skipped")
      failure = Exception.new("block failed")

      raised = expect_raises(Exception) do
        source.transaction do |manager|
          manager.persist(entity)
          raise failure
        end
      end

      raised.should be(failure)
      entity.id.should be_nil
      database.scalar("SELECT count(*) FROM datasource_entities").should eq(0_i64)
    end
  end

  it "performs no write in a query-only entity transaction" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.exec(
        "CREATE TABLE datasource_entities " \
        "(id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT NOT NULL)"
      )
      listener = DataSourceListenerProbe.new
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new,
        listeners: [listener] of LF::Data::Listener
      )

      source.transaction { |manager| manager.find(DataSourceEntity, 1_i64) }

      listener.events.should eq([
        "begin",
        "statement:Select",
        "transaction:Committed",
      ])
      database.scalar("SELECT count(*) FROM datasource_entities").should eq(0_i64)
    end
  end

  it "rejects entity operations through an escaped manager" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.exec(
        "CREATE TABLE datasource_entities " \
        "(id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT NOT NULL)"
      )
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )
      escaped = nil.as(LF::Data::EntityManager?)

      source.transaction { |manager| escaped = manager }

      expect_raises(LF::Data::ClosedEntityManagerError) do
        escaped.not_nil!.persist(DataSourceEntity.new("late"))
      end
      expect_raises(LF::Data::ClosedEntityManagerError) do
        escaped.not_nil!.find(DataSourceEntity, 1_i64)
      end
    end
  end
end
