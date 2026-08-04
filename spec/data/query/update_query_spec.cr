require "./support/bulk_query"

describe LF::Data::Query::UpdateQuery do
  fields = BulkQueryRecord::Fields

  it "executes typed SET and repeated WHERE clauses" do
    with_bulk_query_source do |database, source, listener|
      affected = source.transaction do |manager|
        manager.update(BulkQueryRecord)
          .set(fields.title, "updated")
          .set(fields.active, false)
          .where(fields.active.eq(true))
          .where(fields.id.gte(2_i64))
          .execute
      end

      affected.should eq(1_i64)
      database.query_one(
        "SELECT title, active FROM bulk_query_records WHERE id = 3"
      ) do |result|
        result.read(String).should eq("updated")
        result.read(Bool).should be_false
      end
      listener.statements.last.sql.should eq(
        %(UPDATE "bulk_query_records" SET "title" = ?, "active" = ? ) +
        %(WHERE ("active" = ?) AND ("id" >= ?))
      )
    end
  end

  it "replaces a repeated field value without changing first field order" do
    with_bulk_query_source do |database, source, listener|
      source.transaction do |manager|
        manager.update(BulkQueryRecord)
          .set(fields.title, "first")
          .set(fields.active, false)
          .set(fields.title, "last")
          .where(fields.id.eq(1_i64))
          .execute
      end

      database.scalar(
        "SELECT title FROM bulk_query_records WHERE id = 1"
      ).should eq("last")
      listener.statements.last.sql.should start_with(
        %(UPDATE "bulk_query_records" SET "title" = ?, "active" = ?)
      )
    end
  end

  it "allows an explicit whole-table update" do
    with_bulk_query_source do |database, source, _listener|
      affected = source.transaction do |manager|
        manager.update(BulkQueryRecord)
          .set(fields.active, false)
          .execute
      end

      affected.should eq(3_i64)
      database.scalar(
        "SELECT count(*) FROM bulk_query_records WHERE active = 0"
      ).should eq(3_i64)
    end
  end

  it "rejects pending per-entity operations of the same type" do
    with_bulk_query_source do |_database, source, listener|
      source.transaction do |manager|
        pending = BulkQueryRecord.new(4_i64, "pending", true)
        manager.persist(pending)

        error = expect_raises(LF::Data::EntityStateError) do
          manager.update(BulkQueryRecord)
            .set(fields.active, false)
            .execute
        end

        error.operation.should eq(:bulk_update)
        listener.statements.should be_empty
        manager.remove(pending)
      end
    end
  end

  it "allows pending per-entity operations of another type" do
    with_bulk_query_source do |database, source, _listener|
      source.transaction do |manager|
        pending = OtherBulkQueryRecord.new(1_i64, "pending")
        manager.persist(pending)

        manager.update(BulkQueryRecord)
          .set(fields.active, false)
          .where(fields.id.eq(1_i64))
          .execute

        manager.remove(pending)
      end

      database.scalar(
        "SELECT active FROM bulk_query_records WHERE id = 1"
      ).should eq(0_i64)
    end
  end

  it "detaches managed entities after a successful bulk update" do
    with_bulk_query_source do |_database, source, _listener|
      source.transaction do |manager|
        managed = manager.find(BulkQueryRecord, 1_i64).not_nil!

        manager.update(BulkQueryRecord)
          .set(fields.title, "database")
          .where(fields.id.eq(1_i64))
          .execute

        expect_raises(LF::Data::DetachedEntityError) do
          manager.persist(managed)
        end
      end
    end
  end

  {
    {"bulk_update_no_set.cr", "at least one SET"},
    {"bulk_update_id.cr", "ID field"},
    {"bulk_update_version.cr", "version field"},
    {"bulk_update_wrong_value.cr", "PropertyType"},
    {"bulk_update_cross_entity_set.cr", "not update entity"},
    {"bulk_delete_cross_entity_where.cr", "not bulk entity"},
  }.each do |fixture_case|
    fixture_name, expected = fixture_case

    it "rejects #{fixture_name}" do
      fixture = File.expand_path("../../fixtures/data/#{fixture_name}", __DIR__)
      result = LF::DataSpecSupport.compile_fixture(fixture)

      result[:status].success?.should be_false
      result[:error].should contain(expected)
    end
  end
end
