require "../spec_helper"
require "../../../src/opal/data"
require "../../../src/opal/data/dialects/sqlite"
require "../support/sqlite_database"

@[LF::Data::Table("select_query_records")]
private class SelectQueryRecord
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  property title : String
  getter active : Bool
  getter score : Int32

  def initialize(@id, @title, @active, @score)
  end
end

private class SelectQueryListener
  include LF::Data::Listener

  getter statements = [] of LF::Data::StatementCompletionEvent

  def on_statement_completion(event : LF::Data::StatementCompletionEvent) : Nil
    @statements << event
  end
end

private def with_select_query_source(& : DB::Database, LF::Data::DataSource, SelectQueryListener ->)
  LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
    database.exec(
      "CREATE TABLE select_query_records (" \
      "id INTEGER PRIMARY KEY, title TEXT NOT NULL, " \
      "active INTEGER NOT NULL, score INTEGER NOT NULL)"
    )
    {
      {1_i64, "one", true, 10},
      {2_i64, "two", false, 20},
      {3_i64, "three", true, 30},
      {4_i64, "four", true, 40},
    }.each do |row|
      database.exec(
        "INSERT INTO select_query_records (id, title, active, score) " \
        "VALUES (?, ?, ?, ?)",
        *row
      )
    end
    listener = SelectQueryListener.new
    source = LF::Data::DataSource.new(
      database,
      dialect: LF::Data::Dialects::SQLite.new,
      listeners: [listener] of LF::Data::Listener
    )
    yield database, source, listener
  ensure
    source.try &.close
  end
end

describe LF::Data::Query::SelectQuery do
  fields = SelectQueryRecord::Fields

  it "executes repeated predicates, ordering, limit, and offset with stable args" do
    with_select_query_source do |_database, source, listener|
      records = source.transaction do |manager|
        manager.query(SelectQueryRecord)
          .where(fields.active.eq(true))
          .where(fields.score.gte(20))
          .order_by(fields.score.desc)
          .limit(2)
          .offset(1)
          .to_a
      end

      records.map(&.id).should eq([3_i64])
      listener.statements.last.operation.select?.should be_true
      listener.statements.last.sql.should end_with(
        %(WHERE ("active" = ?) AND ("score" >= ?) ) +
        %(ORDER BY "score" DESC LIMIT ? OFFSET ?)
      )
    end
  end

  it "keeps the base query immutable" do
    with_select_query_source do |_database, source, _listener|
      source.transaction do |manager|
        base = manager.query(SelectQueryRecord).order_by(fields.id.asc)
        active = base.where(fields.active.eq(true))

        base.to_a.map(&.id).should eq([1_i64, 2_i64, 3_i64, 4_i64])
        active.to_a.map(&.id).should eq([1_i64, 3_i64, 4_i64])
      end
    end
  end

  it "implements first, count, and exists terminal semantics" do
    with_select_query_source do |_database, source, listener|
      source.transaction do |manager|
        query = manager.query(SelectQueryRecord)
          .where(fields.active.eq(true))
          .order_by(fields.score.desc)
          .limit(1)
          .offset(1)

        query.first?.not_nil!.id.should eq(3_i64)
        query.count.should eq(3_i64)
        query.exists?.should be_true
        manager.query(SelectQueryRecord)
          .where(fields.id.eq(99_i64))
          .exists?.should be_false
      end

      listener.statements.map(&.sql).should contain(
        %(SELECT COUNT(*) FROM "select_query_records" WHERE "active" = ?)
      )
    end
  end

  it "returns no row when the query limit is zero" do
    with_select_query_source do |_database, source, listener|
      source.transaction do |manager|
        manager.query(SelectQueryRecord)
          .order_by(fields.id.asc)
          .limit(0)
          .first?.should be_nil
      end

      listener.statements.should be_empty
    end
  end

  it "reuses an existing managed identity without replacing its fields" do
    with_select_query_source do |_database, source, _listener|
      source.transaction do |manager|
        found = manager.find(SelectQueryRecord, 1_i64).not_nil!
        found.title = "in-memory"

        queried = manager.query(SelectQueryRecord)
          .where(fields.id.eq(1_i64))
          .first?
          .not_nil!

        queried.same?(found).should be_true
        queried.title.should eq("in-memory")
      end
    end
  end

  it "rejects negative pagination before executing SQL" do
    with_select_query_source do |_database, source, listener|
      source.transaction do |manager|
        query = manager.query(SelectQueryRecord)

        limit_error = expect_raises(LF::Data::InvalidQueryError) do
          query.limit(-1)
        end
        limit_error.component.should eq(:limit)
        limit_error.value.should eq(-1_i64)

        offset_error = expect_raises(LF::Data::InvalidQueryError) do
          query.offset(-1)
        end
        offset_error.component.should eq(:offset)
        offset_error.value.should eq(-1_i64)
        listener.statements.should be_empty
      end
    end
  end

  it "never flushes pending writes before a SELECT terminal" do
    with_select_query_source do |_database, source, listener|
      source.transaction do |manager|
        manager.persist(SelectQueryRecord.new(5_i64, "pending", true, 50))

        manager.query(SelectQueryRecord).to_a.size.should eq(4)
        manager.query(SelectQueryRecord).first?.not_nil!.id.should eq(1_i64)
        manager.query(SelectQueryRecord).count.should eq(4_i64)
        manager.query(SelectQueryRecord).exists?.should be_true
        listener.statements.map(&.operation).all?(&.select?).should be_true

        manager.flush
        manager.query(SelectQueryRecord).count.should eq(5_i64)
      end
    end
  end
end
