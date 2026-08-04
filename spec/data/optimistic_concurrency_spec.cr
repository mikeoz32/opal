require "./support/optimistic_record"

@[LF::Data::Table("concurrent_unversioned_records")]
private class ConcurrentUnversionedRecord
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  property title : String

  def initialize(@id : Int64, @title : String)
  end
end

private def with_concurrent_optimistic_managers(
  & : DB::Database, LF::Data::EntityManager, LF::Data::EntityManager ->
) : Nil
  LF::DataSpecSupport::SQLiteDatabase.with_file do |first_database, path|
    second_database = DB.open("sqlite3:#{path}")
    prepare_optimistic_records(first_database)
    insert_optimistic_record(first_database, 1_i64, "initial")
    dispatcher = LF::Data::Internal::ListenerDispatcher.new
    dialect = LF::Data::Dialects::SQLite.new

    first_database.using_connection do |first_connection|
      second_database.using_connection do |second_connection|
        first_manager = LF::Data::EntityManager.new(
          first_connection,
          dialect,
          dispatcher
        )
        second_manager = LF::Data::EntityManager.new(
          second_connection,
          dialect,
          dispatcher
        )

        begin
          yield first_database, first_manager, second_manager
        ensure
          first_manager.close
          second_manager.close
        end
      end
    end
  ensure
    second_database.try &.close
  end
end

describe "optimistic locking concurrency" do
  it "rejects an update loaded before another manager commits" do
    with_concurrent_optimistic_managers do |database, first_manager, second_manager|
      first = first_manager.find(OptimisticRecord, 1_i64).not_nil!
      second = second_manager.find(OptimisticRecord, 1_i64).not_nil!

      first.title = "first"
      first_manager.persist(first)
      first_manager.flush

      second.title = "second"
      second_manager.persist(second)
      error = expect_raises(LF::Data::OptimisticLockError) do
        second_manager.flush
      end

      error.operation.should eq(:update)
      error.expected_version.should eq(0_i64)
      second.version.should eq(0_i64)
      database.query_one(
        "SELECT title, version FROM optimistic_records WHERE id = 1"
      ) do |result|
        result.read(String).should eq("first")
        result.read(Int64).should eq(1_i64)
      end

      fresh_source = optimistic_source(database)
      fresh_source.transaction do |manager|
        fresh = manager.find(OptimisticRecord, 1_i64).not_nil!
        fresh.title.should eq("first")
        fresh.version.should eq(1_i64)
      end
      fresh_source.close
    end
  end

  it "rejects a delete loaded before another manager updates" do
    with_concurrent_optimistic_managers do |database, first_manager, second_manager|
      first = first_manager.find(OptimisticRecord, 1_i64).not_nil!
      second = second_manager.find(OptimisticRecord, 1_i64).not_nil!

      first.title = "first"
      first_manager.persist(first)
      first_manager.flush

      second_manager.remove(second)
      error = expect_raises(LF::Data::OptimisticLockError) do
        second_manager.flush
      end

      error.operation.should eq(:delete)
      error.expected_version.should eq(0_i64)
      database.query_one(
        "SELECT title, version FROM optimistic_records WHERE id = 1"
      ) do |result|
        result.read(String).should eq("first")
        result.read(Int64).should eq(1_i64)
      end
    end
  end

  it "keeps non-versioned zero-row behavior unchanged" do
    LF::DataSpecSupport::SQLiteDatabase.with_file do |first_database, path|
      second_database = DB.open("sqlite3:#{path}")
      first_database.exec(
        "CREATE TABLE concurrent_unversioned_records " \
        "(id INTEGER PRIMARY KEY, title TEXT NOT NULL)"
      )
      first_database.exec(
        "INSERT INTO concurrent_unversioned_records (id, title) VALUES (1, 'value')"
      )
      dispatcher = LF::Data::Internal::ListenerDispatcher.new
      dialect = LF::Data::Dialects::SQLite.new

      first_database.using_connection do |first_connection|
        second_database.using_connection do |second_connection|
          first_manager = LF::Data::EntityManager.new(first_connection, dialect, dispatcher)
          second_manager = LF::Data::EntityManager.new(second_connection, dialect, dispatcher)
          first = first_manager.find(ConcurrentUnversionedRecord, 1_i64).not_nil!
          second = second_manager.find(ConcurrentUnversionedRecord, 1_i64).not_nil!

          first_manager.remove(first)
          first_manager.flush
          second_manager.remove(second)

          error = expect_raises(LF::Data::EntityStateError) do
            second_manager.flush
          end
          error.operation.should eq(:delete)
        ensure
          first_manager.try &.close
          second_manager.try &.close
        end
      end
    ensure
      second_database.try &.close
    end
  end
end
