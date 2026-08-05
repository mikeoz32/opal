require "../spec_helper"
require "../../../src/opal/data"
require "../../../src/opal/data/dialects/sqlite"
require "../support/sqlite_database"

private module DynamicTitleConverter
  @@dumps = 0

  def self.load(result : DB::ResultSet) : String
    result.read(String).upcase
  end

  def self.dump(value : String) : String
    @@dumps += 1
    value.downcase
  end

  def self.dumps : Int32
    @@dumps
  end

  def self.reset : Nil
    @@dumps = 0
  end
end

@[LF::Data::Table("dynamic_query_records")]
private class DynamicQueryRecord
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::Column(name: "stored_title", converter: DynamicTitleConverter)]
  getter title : String

  getter active : Bool
  getter score : Int32
  getter note : String?

  def initialize(@id, @title, @active, @score, @note : String? = nil)
  end
end

private class DynamicQueryListener
  include LF::Data::Listener

  getter statements = [] of LF::Data::StatementCompletionEvent

  def on_statement_completion(event : LF::Data::StatementCompletionEvent) : Nil
    @statements << event
  end
end

private def with_dynamic_query_source(& : LF::Data::DataSource, DynamicQueryListener ->)
  LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
    database.exec(
      "CREATE TABLE dynamic_query_records (" \
      "id INTEGER PRIMARY KEY, stored_title TEXT NOT NULL, " \
      "active INTEGER NOT NULL, score INTEGER NOT NULL, note TEXT)"
    )
    {
      {1_i64, "one", true, 10},
      {2_i64, "two", false, 20},
      {3_i64, "three", true, 30},
      {4_i64, "four", true, 40},
    }.each do |row|
      database.exec(
        "INSERT INTO dynamic_query_records " \
        "(id, stored_title, active, score) VALUES (?, ?, ?, ?)",
        *row
      )
    end
    listener = DynamicQueryListener.new
    source = LF::Data::DataSource.new(
      database,
      dialect: LF::Data::Dialects::SQLite.new,
      listeners: [listener] of LF::Data::Listener
    )
    yield source, listener
  ensure
    source.try &.close
  end
end

describe LF::Data::Query::DynamicQuery do
  fields = DynamicQueryRecord::Fields

  it "accepts a runtime collection of typed predicates" do
    with_dynamic_query_source do |source, listener|
      active = fields.active.eq(true)
      scored = fields.score.gte(20)
      filters = [active, scored] of typeof(active) | typeof(scored)

      records = source.transaction do |manager|
        query = manager.dynamic_query(DynamicQueryRecord)
        filters.each { |filter| query.where(filter) }
        query
          .where(fields.id.in([1_i64, 3_i64, 4_i64]))
          .order_by(fields.score.desc)
          .limit(2)
          .offset(1)
          .to_a
      end

      records.map(&.id).should eq([3_i64])
      listener.statements.last.sql.should end_with(
        "WHERE (\"active\" = ?) AND (\"score\" >= ?) AND " \
        "(\"id\" IN (?, ?, ?)) " \
        "ORDER BY \"score\" DESC LIMIT ? OFFSET ?"
      )
    end
  end

  it "dumps runtime IN values once and renders empty IN as false" do
    with_dynamic_query_source do |source, listener|
      DynamicTitleConverter.reset

      source.transaction do |manager|
        query = manager.dynamic_query(DynamicQueryRecord)
          .where(fields.title.in(["THREE", "FOUR"]))

        DynamicTitleConverter.dumps.should eq(2)
        query.to_a.map(&.id).should eq([3_i64, 4_i64])
        DynamicTitleConverter.dumps.should eq(2)

        manager.dynamic_query(DynamicQueryRecord)
          .where(fields.id.in([] of Int64))
          .to_a.should be_empty
      end

      listener.statements.last.sql.should end_with("WHERE (0 = 1)")
      listener.statements.last.sql.should_not contain("THREE")
    end
  end

  it "preserves grouping and never interpolates user values" do
    with_dynamic_query_source do |source, listener|
      user_value = %(x' OR 1 = 1 --)

      source.transaction do |manager|
        manager.dynamic_query(DynamicQueryRecord)
          .where(
            fields.title.eq(user_value).or(
              fields.active.eq(false).and(fields.score.lt(30))
            )
          )
          .to_a.map(&.id).should eq([2_i64])
      end

      sql = listener.statements.last.sql
      sql.should_not contain(user_value)
      sql.should contain(
        %(WHERE (("stored_title" = ?) OR (("active" = ?) AND ("score" < ?))))
      )
    end
  end

  it "renders nullable equality and inequality without NULL bind values" do
    with_dynamic_query_source do |source, listener|
      source.transaction do |manager|
        manager.dynamic_query(DynamicQueryRecord)
          .where(fields.note.eq(nil))
          .to_a.size.should eq(4)
        manager.dynamic_query(DynamicQueryRecord)
          .where(fields.note.ne(nil))
          .to_a.should be_empty
      end

      listener.statements[-2].sql.should end_with(%(WHERE ("note" IS NULL)))
      listener.statements[-1].sql.should end_with(%(WHERE ("note" IS NOT NULL)))
    end
  end

  it "implements terminal semantics without implicit flush" do
    with_dynamic_query_source do |source, listener|
      source.transaction do |manager|
        manager.persist(DynamicQueryRecord.new(5_i64, "pending", true, 50))
        query = manager.dynamic_query(DynamicQueryRecord)
          .where(fields.active.eq(true))
          .order_by(fields.score.desc)
          .limit(1)
          .offset(1)

        query.first?.not_nil!.id.should eq(3_i64)
        query.count.should eq(3_i64)
        query.exists?.should be_true
        query.to_a.map(&.id).should eq([3_i64])
        listener.statements.map(&.operation).all?(&.select?).should be_true

        manager.flush
        manager.dynamic_query(DynamicQueryRecord).count.should eq(5_i64)
      end
    end
  end

  it "rejects negative pagination before rendering or executing" do
    with_dynamic_query_source do |source, listener|
      source.transaction do |manager|
        query = manager.dynamic_query(DynamicQueryRecord)

        expect_raises(LF::Data::InvalidQueryError) { query.limit(-1) }
        expect_raises(LF::Data::InvalidQueryError) { query.offset(-1) }
        listener.statements.should be_empty
      end
    end
  end

  it "returns no row when the query limit is zero" do
    with_dynamic_query_source do |source, _listener|
      source.transaction do |manager|
        manager.dynamic_query(DynamicQueryRecord)
          .order_by(fields.id.asc)
          .limit(0)
          .first?.should be_nil
      end
    end
  end

  it "uses the SQLite offset-only runtime policy" do
    with_dynamic_query_source do |source, listener|
      records = source.transaction do |manager|
        manager.dynamic_query(DynamicQueryRecord)
          .order_by(fields.id.asc)
          .offset(2)
          .to_a
      end

      records.map(&.id).should eq([3_i64, 4_i64])
      listener.statements.last.sql.should end_with(
        %(ORDER BY "id" ASC LIMIT -1 OFFSET ?)
      )
    end
  end

  it "keeps runtime-arity IN unavailable to the static builder" do
    fixture = File.expand_path("../../fixtures/data/query_static_array_in.cr", __DIR__)
    result = LF::DataSpecSupport.compile_fixture(fixture)

    result[:status].success?.should be_false
  end
end
