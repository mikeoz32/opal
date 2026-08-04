require "./support/optimistic_record"

private class OptimisticFlushListener
  include LF::Data::Listener

  getter statements = [] of LF::Data::StatementCompletionEvent

  def on_statement_completion(event : LF::Data::StatementCompletionEvent) : Nil
    @statements << event
  end
end

private def optimistic_source(
  database : DB::Database,
  listener : LF::Data::Listener,
) : LF::Data::DataSource
  LF::Data::DataSource.new(
    database,
    dialect: LF::Data::Dialects::SQLite.new,
    listeners: [listener] of LF::Data::Listener
  )
end

describe "optimistic locking explicit flush" do
  it "advances the version for each successful update batch" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      prepare_optimistic_records(database)
      insert_optimistic_record(database, 1_i64, "initial")
      source = optimistic_source(database)

      source.transaction do |manager|
        entity = manager.find(OptimisticRecord, 1_i64).not_nil!
        entity.title = "first"
        manager.persist(entity)
        manager.flush
        entity.version.should eq(1_i64)

        entity.title = "second"
        manager.persist(entity)
        manager.flush
        entity.version.should eq(2_i64)
      end

      database.query_one(
        "SELECT title, version FROM optimistic_records WHERE id = 1"
      ) do |result|
        result.read(String).should eq("second")
        result.read(Int64).should eq(2_i64)
      end
    ensure
      source.try &.close
    end
  end

  it "coalesces repeated persist calls into one version increment" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      prepare_optimistic_records(database)
      insert_optimistic_record(database, 1_i64, "initial")
      listener = OptimisticFlushListener.new
      source = optimistic_source(database, listener)

      source.transaction do |manager|
        entity = manager.find(OptimisticRecord, 1_i64).not_nil!
        entity.title = "first"
        manager.persist(entity)
        entity.title = "final"
        manager.persist(entity)
      end

      listener.statements.map(&.operation).should eq([
        LF::Data::StatementOperation::Select,
        LF::Data::StatementOperation::Update,
      ])
      database.scalar(
        "SELECT version FROM optimistic_records WHERE id = 1"
      ).should eq(1_i64)
    ensure
      source.try &.close
    end
  end

  it "coalesces a pending update into only a versioned delete" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      prepare_optimistic_records(database)
      insert_optimistic_record(database, 1_i64, "initial")
      listener = OptimisticFlushListener.new
      source = optimistic_source(database, listener)

      source.transaction do |manager|
        entity = manager.find(OptimisticRecord, 1_i64).not_nil!
        entity.title = "not-written"
        manager.persist(entity)
        manager.remove(entity)
      end

      listener.statements.map(&.operation).should eq([
        LF::Data::StatementOperation::Select,
        LF::Data::StatementOperation::Delete,
      ])
      database.scalar(
        "SELECT count(*) FROM optimistic_records"
      ).should eq(0_i64)
    ensure
      source.try &.close
    end
  end

  it "stops before later queued work after a stale update" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      prepare_optimistic_records(database)
      insert_optimistic_record(database, 1_i64, "first")
      insert_optimistic_record(database, 2_i64, "second")
      listener = OptimisticFlushListener.new
      source = optimistic_source(database, listener)

      expect_raises(LF::Data::OptimisticLockError) do
        source.transaction do |manager|
          stale = manager.find(OptimisticRecord, 1_i64).not_nil!
          later = manager.find(OptimisticRecord, 2_i64).not_nil!
          manager.connection.exec(
            "UPDATE optimistic_records SET version = 1 WHERE id = 1"
          )
          stale.title = "stale"
          later.title = "must-not-run"
          manager.persist(stale)
          manager.persist(later)

          begin
            manager.flush
          rescue error : LF::Data::OptimisticLockError
            expect_raises(LF::Data::FailedEntityManagerError) do
              manager.flush
            end
            raise error
          end
        end
      end

      listener.statements.map(&.operation).should eq([
        LF::Data::StatementOperation::Select,
        LF::Data::StatementOperation::Select,
        LF::Data::StatementOperation::Update,
      ])
      database.query_one(
        "SELECT title, version FROM optimistic_records WHERE id = 2"
      ) do |result|
        result.read(String).should eq("second")
        result.read(Int64).should eq(0_i64)
      end
    ensure
      source.try &.close
    end
  end

  it "cannot roll back in-memory state after a later application failure" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      prepare_optimistic_records(database)
      insert_optimistic_record(database, 1_i64, "initial")
      source = optimistic_source(database)
      entity = nil.as(OptimisticRecord?)
      application_error = Exception.new("abort after flush")

      raised = expect_raises(Exception) do
        source.transaction do |manager|
          entity = manager.find(OptimisticRecord, 1_i64).not_nil!
          entity.not_nil!.title = "rolled-back"
          manager.persist(entity.not_nil!)
          manager.flush
          entity.not_nil!.version.should eq(1_i64)
          raise application_error
        end
      end

      raised.should be(application_error)
      entity.not_nil!.title.should eq("rolled-back")
      entity.not_nil!.version.should eq(1_i64)
      database.query_one(
        "SELECT title, version FROM optimistic_records WHERE id = 1"
      ) do |result|
        result.read(String).should eq("initial")
        result.read(Int64).should eq(0_i64)
      end
    ensure
      source.try &.close
    end
  end
end
