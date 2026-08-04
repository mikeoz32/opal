require "./query/support/bulk_query"

private class RawConnectionFlushError < Exception
end

private class RawConnectionFailingEntityManager < LF::Data::EntityManager
  protected def do_flush : Nil
    raise RawConnectionFlushError.new("flush failed")
  end
end

private class RawConnectionFailingDataSource < LF::Data::DataSource
  protected def build_entity_manager(
    connection : DB::Connection,
    dialect : LF::Data::Dialect,
    dispatcher : LF::Data::Internal::ListenerDispatcher,
  ) : LF::Data::EntityManager
    RawConnectionFailingEntityManager.new(connection, dialect, dispatcher)
  end
end

describe "EntityManager raw connection contract" do
  it "exposes the active transaction connection as a read-only getter" do
    with_bulk_query_source do |database, source, _listener|
      source.transaction do |manager|
        manager.responds_to?(:connection).should be_true
        manager.responds_to?(:connection=).should be_false
        manager.connection.exec(
          "INSERT INTO bulk_query_records (id, title, active, version) " \
          "VALUES (?, ?, ?, ?)",
          4_i64,
          "raw",
          true,
          0_i64
        )
      end

      database.scalar(
        "SELECT title FROM bulk_query_records WHERE id = 4"
      ).should eq("raw")
    end
  end

  it "rejects connection access after manager close" do
    with_bulk_query_source do |_database, source, _listener|
      escaped = nil.as(LF::Data::EntityManager?)
      source.transaction { |manager| escaped = manager }

      error = expect_raises(LF::Data::ClosedEntityManagerError) do
        escaped.not_nil!.connection
      end
      error.operation.should eq(:connection)
    end
  end

  it "rejects connection access after a flush failure" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      source = RawConnectionFailingDataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )

      failure = expect_raises(RawConnectionFlushError) do
        source.transaction do |manager|
          begin
            manager.flush
          rescue error : RawConnectionFlushError
            failed = expect_raises(LF::Data::FailedEntityManagerError) do
              manager.connection
            end
            failed.operation.should eq(:connection)
            raise error
          end
        end
      end

      failure.should_not be_a(LF::Data::Error)
    ensure
      source.try &.close
    end
  end

  it "preserves raw driver errors" do
    with_bulk_query_source do |_database, source, _listener|
      source.transaction do |manager|
        error = expect_raises(SQLite3::Exception) do
          manager.connection.exec("UPDATE table_that_does_not_exist SET value = 1")
        end

        error.should_not be_a(LF::Data::Error)
      end
    end
  end

  it "does not infer raw-write identity invalidation and supports explicit clear" do
    with_bulk_query_source do |_database, source, _listener|
      source.transaction do |manager|
        managed = manager.find(BulkQueryRecord, 1_i64).not_nil!
        manager.connection.exec(
          "UPDATE bulk_query_records SET title = ? WHERE id = ?",
          "raw-change",
          1_i64
        )

        cached = manager.find(BulkQueryRecord, 1_i64).not_nil!
        cached.same?(managed).should be_true
        cached.title.should eq("one")

        manager.clear(BulkQueryRecord)
        reloaded = manager.find(BulkQueryRecord, 1_i64).not_nil!
        reloaded.same?(managed).should be_false
        reloaded.title.should eq("raw-change")
        expect_raises(LF::Data::DetachedEntityError) do
          manager.persist(managed)
        end
      end
    end
  end

  it "rejects clear while that entity type has pending operations" do
    with_bulk_query_source do |_database, source, _listener|
      source.transaction do |manager|
        pending = BulkQueryRecord.new(4_i64, "pending", true)
        manager.persist(pending)

        error = expect_raises(LF::Data::EntityStateError) do
          manager.clear(BulkQueryRecord)
        end

        error.operation.should eq(:clear)
        manager.remove(pending)
      end
    end
  end

  it "allows clear while another entity type has pending operations" do
    with_bulk_query_source do |_database, source, _listener|
      source.transaction do |manager|
        managed = manager.find(BulkQueryRecord, 1_i64).not_nil!
        pending = OtherBulkQueryRecord.new(1_i64, "pending")
        manager.persist(pending)

        manager.clear(BulkQueryRecord)

        expect_raises(LF::Data::DetachedEntityError) do
          manager.persist(managed)
        end
        manager.remove(pending)
      end
    end
  end
end
