require "../spec_helper"
require "../../../src/opal/data"
require "../../../src/opal/data/dialects/sqlite"

@[LF::Data::Table("static_query_records")]
private class StaticQueryRecord
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  getter title : String
  getter active : Bool
  getter score : Int32
  getter note : String?

  def initialize(@id, @title, @active, @score, @note)
  end
end

@[LF::Data::Table]
private class StaticDefaultTableRecord
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  def initialize(@id)
  end
end

private class StaticOnlySQLiteDialect < LF::Data::Dialects::SQLite
  def quote_identifier(identifier : String) : String
    raise "static SELECT called runtime quote_identifier"
  end

  def placeholder(position : Int32) : String
    raise "static SELECT called runtime placeholder"
  end
end

private def static_rows_plan(
  dialect : LF::Data::Dialect,
  entity : T.class,
  predicate : P,
  orders : O = LF::Data::Query::NoOrdering.new,
  limit : L = LF::Data::Query::NoLimit.new,
  offset : F = LF::Data::Query::NoOffset.new,
) forall T, P, O, L, F
  dialect.select_plan(
    T,
    LF::Data::Query::Rows(LF::Data::Query::SelectQuery(T, P, O, L, F))
  )
end

private def static_first_plan(
  dialect : LF::Data::Dialect,
  entity : T.class,
  predicate : P,
  orders : O = LF::Data::Query::NoOrdering.new,
  limit : L = LF::Data::Query::NoLimit.new,
  offset : F = LF::Data::Query::NoOffset.new,
) forall T, P, O, L, F
  dialect.select_plan(
    T,
    LF::Data::Query::First(LF::Data::Query::SelectQuery(T, P, O, L, F))
  )
end

private def static_count_plan(
  dialect : LF::Data::Dialect,
  entity : T.class,
  predicate : P,
  orders : O = LF::Data::Query::NoOrdering.new,
  limit : L = LF::Data::Query::NoLimit.new,
  offset : F = LF::Data::Query::NoOffset.new,
) forall T, P, O, L, F
  dialect.select_plan(
    T,
    LF::Data::Query::Count(LF::Data::Query::SelectQuery(T, P, O, L, F))
  )
end

private def static_exists_plan(
  dialect : LF::Data::Dialect,
  entity : T.class,
  predicate : P,
  orders : O = LF::Data::Query::NoOrdering.new,
  limit : L = LF::Data::Query::NoLimit.new,
  offset : F = LF::Data::Query::NoOffset.new,
) forall T, P, O, L, F
  dialect.select_plan(
    T,
    LF::Data::Query::Exists(LF::Data::Query::SelectQuery(T, P, O, L, F))
  )
end

describe LF::Data::SQL::StaticPlanCompiler do
  dialect = LF::Data::Dialects::SQLite.new
  fields = StaticQueryRecord::Fields

  it "compiles every comparison operator as a static SELECT plan" do
    static_rows_plan(dialect, StaticQueryRecord, fields.id.eq(1_i64))
      .sql.should end_with(%(WHERE "id" = ?))
    static_rows_plan(dialect, StaticQueryRecord, fields.id.ne(1_i64))
      .sql.should end_with(%(WHERE "id" <> ?))
    static_rows_plan(dialect, StaticQueryRecord, fields.score.lt(10))
      .sql.should end_with(%(WHERE "score" < ?))
    static_rows_plan(dialect, StaticQueryRecord, fields.score.lte(10))
      .sql.should end_with(%(WHERE "score" <= ?))
    static_rows_plan(dialect, StaticQueryRecord, fields.score.gt(10))
      .sql.should end_with(%(WHERE "score" > ?))
    static_rows_plan(dialect, StaticQueryRecord, fields.score.gte(10))
      .sql.should end_with(%(WHERE "score" >= ?))
    static_rows_plan(dialect, StaticQueryRecord, fields.title.like("%x"))
      .sql.should end_with(%(WHERE "title" LIKE ?))
  end

  it "preserves nested grouping and depth-first predicate order" do
    predicate = fields.active.eq(false).and(
      fields.title.like("%opal%").or(fields.note.is_nil)
    ).not

    static_rows_plan(dialect, StaticQueryRecord, predicate).sql.should eq(
      %(SELECT "id", "title", "active", "score", "note" ) +
      %(FROM "static_query_records" ) +
      %(WHERE NOT (("active" = ?) AND (("title" LIKE ?) OR ("note" IS NULL))))
    )
    predicate.__lf_args.should eq({false, "%opal%"})
  end

  it "compiles fixed and empty IN predicates without interpolating values" do
    static_rows_plan(
      dialect,
      StaticQueryRecord,
      fields.id.in({1_i64, 2_i64, 3_i64})
    ).sql.should end_with(%(WHERE "id" IN (?, ?, ?)))

    static_rows_plan(
      dialect,
      StaticQueryRecord,
      fields.id.in(Tuple.new)
    ).sql.should end_with("WHERE 0 = 1")
  end

  it "compiles nil predicates without bind placeholders" do
    static_rows_plan(
      dialect,
      StaticQueryRecord,
      fields.note.is_nil.or(fields.note.is_not_nil)
    ).sql.should end_with(
      %(WHERE ("note" IS NULL) OR ("note" IS NOT NULL))
    )
  end

  it "compiles eq and ne nil as SQL NULL predicates" do
    static_rows_plan(dialect, StaticQueryRecord, fields.note.eq(nil))
      .sql.should end_with(%(WHERE "note" IS NULL))
    static_rows_plan(dialect, StaticQueryRecord, fields.note.ne(nil))
      .sql.should end_with(%(WHERE "note" IS NOT NULL))
  end

  it "compiles typed ordering and SQLite pagination policy" do
    first_order = LF::Data::Query::OrderList(
      LF::Data::Query::NoOrdering,
      typeof(fields.id.desc),
    ).new
    orders = LF::Data::Query::OrderList(
      typeof(first_order),
      typeof(fields.title.asc),
    ).new

    static_rows_plan(
      dialect,
      StaticQueryRecord,
      LF::Data::Query::NoPredicate.new,
      orders,
      LF::Data::Query::WithLimit.new,
      LF::Data::Query::WithOffset.new
    ).sql.should eq(
      %(SELECT "id", "title", "active", "score", "note" ) +
      %(FROM "static_query_records" ) +
      %(ORDER BY "id" DESC, "title" ASC LIMIT ? OFFSET ?)
    )

    static_rows_plan(
      dialect,
      StaticQueryRecord,
      LF::Data::Query::NoPredicate.new,
      LF::Data::Query::NoOrdering.new,
      LF::Data::Query::NoLimit.new,
      LF::Data::Query::WithOffset.new
    ).sql.should end_with("LIMIT -1 OFFSET ?")
  end

  it "applies first, count, and exists terminal semantics statically" do
    predicate = fields.active.eq(true)
    orders = LF::Data::Query::OrderList(
      LF::Data::Query::NoOrdering,
      typeof(fields.id.desc),
    ).new

    static_first_plan(
      dialect,
      StaticQueryRecord,
      predicate,
      orders,
      LF::Data::Query::WithLimit.new,
      LF::Data::Query::WithOffset.new
    ).sql.should eq(
      %(SELECT "id", "title", "active", "score", "note" ) +
      %(FROM "static_query_records" WHERE "active" = ? ) +
      %(ORDER BY "id" DESC LIMIT 1 OFFSET ?)
    )

    static_count_plan(
      dialect,
      StaticQueryRecord,
      predicate,
      orders,
      LF::Data::Query::WithLimit.new,
      LF::Data::Query::WithOffset.new
    ).sql.should eq(
      %(SELECT COUNT(*) FROM "static_query_records" WHERE "active" = ?)
    )

    static_exists_plan(
      dialect,
      StaticQueryRecord,
      predicate,
      orders,
      LF::Data::Query::WithLimit.new,
      LF::Data::Query::WithOffset.new
    ).sql.should eq(
      %(SELECT 1 FROM "static_query_records" WHERE "active" = ? LIMIT 1)
    )
  end

  it "does not use runtime dialect rendering methods" do
    plan = static_rows_plan(
      StaticOnlySQLiteDialect.new,
      StaticQueryRecord,
      fields.title.eq("runtime-value")
    )

    plan.sql.should end_with(%(WHERE "title" = ?))
    plan.sql.should_not contain("runtime-value")
  end

  it "derives the table name for a bare Table annotation" do
    static_rows_plan(
      dialect,
      StaticDefaultTableRecord,
      LF::Data::Query::NoPredicate.new
    ).sql.should eq(
      %(SELECT "id" FROM "static_default_table_record")
    )
  end
end
