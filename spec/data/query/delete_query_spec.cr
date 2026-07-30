require "./support/bulk_query"

describe LF::Data::Query::DeleteQuery do
  fields = BulkQueryRecord::Fields

  it "executes repeated typed WHERE clauses" do
    with_bulk_query_source do |database, source, listener|
      affected = source.transaction do |manager|
        manager.delete(BulkQueryRecord)
          .where(fields.active.eq(true))
          .where(fields.id.gt(1_i64))
          .execute
      end

      affected.should eq(1_i64)
      database.scalar(
        "SELECT count(*) FROM bulk_query_records WHERE id = 3"
      ).should eq(0_i64)
      listener.statements.last.sql.should eq(
        %(DELETE FROM "bulk_query_records" ) +
        %(WHERE ("active" = ?) AND ("id" > ?))
      )
    end
  end

  it "allows an explicit whole-table delete" do
    with_bulk_query_source do |database, source, _listener|
      affected = source.transaction do |manager|
        manager.delete(BulkQueryRecord).execute
      end

      affected.should eq(3_i64)
      database.scalar(
        "SELECT count(*) FROM bulk_query_records"
      ).should eq(0_i64)
    end
  end

  it "rejects pending per-entity operations of the same type" do
    with_bulk_query_source do |_database, source, listener|
      source.transaction do |manager|
        pending = BulkQueryRecord.new(4_i64, "pending", true, 0_i64)
        manager.persist(pending)

        error = expect_raises(LF::Data::EntityStateError) do
          manager.delete(BulkQueryRecord).execute
        end

        error.operation.should eq(:bulk_delete)
        listener.statements.should be_empty
        manager.remove(pending)
      end
    end
  end

  it "detaches managed entities after a successful bulk delete" do
    with_bulk_query_source do |_database, source, _listener|
      source.transaction do |manager|
        managed = manager.find(BulkQueryRecord, 1_i64).not_nil!

        manager.delete(BulkQueryRecord)
          .where(fields.id.eq(1_i64))
          .execute

        expect_raises(LF::Data::DetachedEntityError) do
          manager.persist(managed)
        end
      end
    end
  end
end
