require "./support/optimistic_record"

describe "optimistic entity DELETE" do
  it "generates DELETE arguments with the manager expected version last" do
    entity = OptimisticRecord.new(7_i64, "deleted")

    entity.__lf_delete_args(3_i64).should eq({7_i64, 3_i64})
  end

  it "deletes and detaches an entity at the expected version" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      prepare_optimistic_records(database)
      insert_optimistic_record(database, 1_i64, "before", 3_i64)
      source = optimistic_source(database)

      source.transaction do |manager|
        entity = manager.find(OptimisticRecord, 1_i64).not_nil!
        manager.remove(entity)
        manager.flush

        expect_raises(LF::Data::DetachedEntityError) do
          manager.persist(entity)
        end
      end

      database.scalar(
        "SELECT count(*) FROM optimistic_records"
      ).should eq(0_i64)
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
        manager.remove(entity)
      end

      database.scalar(
        "SELECT count(*) FROM optimistic_records"
      ).should eq(0_i64)
    ensure
      source.try &.close
    end
  end

  it "raises a typed stale error and leaves the entity version unchanged" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      prepare_optimistic_records(database)
      insert_optimistic_record(database, 1_i64, "before")
      source = optimistic_source(database)
      entity = nil.as(OptimisticRecord?)

      error = expect_raises(LF::Data::OptimisticLockError) do
        source.transaction do |manager|
          entity = manager.find(OptimisticRecord, 1_i64).not_nil!
          manager.connection.exec(
            "UPDATE optimistic_records SET version = 1 WHERE id = 1"
          )
          manager.remove(entity.not_nil!)
          manager.flush
        end
      end

      error.operation.should eq(:delete)
      error.entity_name.should eq("OptimisticRecord")
      error.entity_id.should eq(1_i64)
      error.expected_version.should eq(0_i64)
      entity.not_nil!.version.should eq(0_i64)
      database.query_one(
        "SELECT title, version FROM optimistic_records WHERE id = 1"
      ) do |result|
        result.read(String).should eq("before")
        result.read(Int64).should eq(0_i64)
      end
    ensure
      source.try &.close
    end
  end
end
