require "./support/optimistic_record"

describe "optimistic entity UPDATE" do
  it "inserts the initial zero version" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      prepare_optimistic_records(database)
      source = optimistic_source(database)
      entity = OptimisticRecord.new(1_i64, "created")

      source.transaction { |manager| manager.persist(entity) }

      entity.version.should eq(0_i64)
      database.query_one(
        "SELECT title, version FROM optimistic_records WHERE id = 1"
      ) do |result|
        result.read(String).should eq("created")
        result.read(Int64).should eq(0_i64)
      end
    ensure
      source.try &.close
    end
  end

  it "generates UPDATE arguments with the manager expected version last" do
    entity = OptimisticRecord.new(7_i64, "updated")

    entity.__lf_update_args(3_i64).should eq({"updated", 7_i64, 3_i64})
  end

  it "increments the stored and in-memory version after a successful update" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      prepare_optimistic_records(database)
      insert_optimistic_record(database, 1_i64, "before", 3_i64)
      source = optimistic_source(database)

      source.transaction do |manager|
        entity = manager.find(OptimisticRecord, 1_i64).not_nil!
        entity.version.should eq(3_i64)
        entity.title = "after"
        manager.persist(entity)
        manager.flush

        entity.version.should eq(4_i64)
      end

      database.query_one(
        "SELECT title, version FROM optimistic_records WHERE id = 1"
      ) do |result|
        result.read(String).should eq("after")
        result.read(Int64).should eq(4_i64)
      end
    ensure
      source.try &.close
    end
  end

  it "uses manager state instead of a changed entity version" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      prepare_optimistic_records(database)
      insert_optimistic_record(database, 1_i64, "before")
      source = optimistic_source(database)

      source.transaction do |manager|
        entity = manager.find(OptimisticRecord, 1_i64).not_nil!
        entity.__lf_write_version(99_i64)
        entity.title = "after"
        manager.persist(entity)
        manager.flush

        entity.version.should eq(1_i64)
      end
    ensure
      source.try &.close
    end
  end

  it "raises a typed stale error and leaves the entity version unchanged" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      prepare_optimistic_records(database)
      insert_optimistic_record(database, 1_i64, "before")
      source = optimistic_source(database)
      escaped = nil.as(LF::Data::EntityManager?)
      entity = nil.as(OptimisticRecord?)

      error = expect_raises(LF::Data::OptimisticLockError) do
        source.transaction do |manager|
          escaped = manager
          entity = manager.find(OptimisticRecord, 1_i64).not_nil!
          manager.connection.exec(
            "UPDATE optimistic_records SET version = 1 WHERE id = 1"
          )
          entity.not_nil!.title = "stale"
          manager.persist(entity.not_nil!)

          begin
            manager.flush
          rescue stale : LF::Data::OptimisticLockError
            expect_raises(LF::Data::FailedEntityManagerError) do
              manager.find(OptimisticRecord, 1_i64)
            end
            raise stale
          end
        end
      end

      error.operation.should eq(:update)
      error.entity_name.should eq("OptimisticRecord")
      error.entity_id.should eq(1_i64)
      error.expected_version.should eq(0_i64)
      entity.not_nil!.version.should eq(0_i64)
      escaped.not_nil!.closed?.should be_true
      database.scalar(
        "SELECT version FROM optimistic_records WHERE id = 1"
      ).should eq(0_i64)
    ensure
      source.try &.close
    end
  end
end
