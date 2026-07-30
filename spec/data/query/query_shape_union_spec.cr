require "../spec_helper"
require "../../../src/opal/data"
require "../../../src/opal/data/dialects/sqlite"
require "../support/sqlite_database"

@[LF::Data::Table("query_shape_union_records")]
private class QueryShapeUnionRecord
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  getter active : Bool

  def initialize(@id, @active)
  end
end

private class QueryShapeUnionListener
  include LF::Data::Listener

  getter statements = [] of LF::Data::StatementCompletionEvent

  def on_statement_completion(event : LF::Data::StatementCompletionEvent) : Nil
    @statements << event
  end
end

private def run_union_query(
  manager : LF::Data::EntityManager,
  active : Bool?,
)
  query = if active.nil?
            manager.query(QueryShapeUnionRecord)
          else
            manager.query(QueryShapeUnionRecord)
              .where(QueryShapeUnionRecord::Fields.active.eq(active))
          end

  query.limit(10).offset(0).to_a
end

describe "static query shape unions" do
  it "compiles one static specialization per runtime branch" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.exec(
        "CREATE TABLE query_shape_union_records " \
        "(id INTEGER PRIMARY KEY, active INTEGER NOT NULL)"
      )
      database.exec(
        "INSERT INTO query_shape_union_records (id, active) VALUES (?, ?)",
        1_i64,
        true
      )
      database.exec(
        "INSERT INTO query_shape_union_records (id, active) VALUES (?, ?)",
        2_i64,
        false
      )
      listener = QueryShapeUnionListener.new
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new,
        listeners: [listener] of LF::Data::Listener
      )

      source.transaction do |manager|
        run_union_query(manager, nil).map(&.id).should eq([1_i64, 2_i64])
        run_union_query(manager, false).map(&.id).should eq([2_i64])
      end

      listener.statements.map(&.sql).should eq([
        %(SELECT "id", "active" FROM "query_shape_union_records" LIMIT ? OFFSET ?),
        %(SELECT "id", "active" FROM "query_shape_union_records" ) +
        %(WHERE "active" = ? LIMIT ? OFFSET ?),
      ])
    ensure
      source.try &.close
    end
  end

  it "compiles the standalone union regression fixture" do
    fixture = File.expand_path("../../fixtures/data/query_shape_union.cr", __DIR__)
    result = LF::DataSpecSupport.compile_fixture(fixture)

    result[:status].success?.should be_true
  end
end
