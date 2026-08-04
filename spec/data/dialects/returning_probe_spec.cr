require "../spec_helper"
require "../../../src/opal/data/dialects/sqlite"

module ReturningProbeSpec
  @[LF::Data::Table("probe_items")]
  class Item
    include LF::Data::Entity

    @[LF::Data::Id(generated: true)]
    getter id : Int64?

    getter name : String

    @[LF::Data::Version]
    getter version : Int64 = 0_i64

    def initialize(@id, @name)
    end
  end

  class Dialect < LF::Data::Dialect
    module StaticSQLPolicy
      IDENTIFIER_OPEN            = %(")
      IDENTIFIER_CLOSE           = %(")
      IDENTIFIER_ESCAPE_FROM     = %(")
      IDENTIFIER_ESCAPE_TO       = %("")
      PLACEHOLDER_STYLE          = :numbered
      PLACEHOLDER_PREFIX         = "$"
      PLACEHOLDER_FIRST_POSITION = 1
      EMPTY_INSERT_STYLE         = :default_values
      GENERATED_KEY_SOURCE       = LF::Data::SQL::GeneratedKeySource::ReturningRow
    end

    STATIC_SQL_POLICY = StaticSQLPolicy
    include LF::Data::SQL::StaticPlanCompiler

    def name : String
      "returning-probe"
    end

    def quote_identifier(identifier : String) : String
      %("#{identifier.gsub("\"", "\"\"")}")
    end

    def placeholder(position : Int32) : String
      "$#{position}"
    end

    def supports?(capability : LF::Data::DialectCapability) : Bool
      capability.returning_row?
    end
  end
end

describe "returning dialect probe" do
  it "generates numbered placeholders and a returned generated key" do
    dialect : LF::Data::Dialect = ReturningProbeSpec::Dialect.new

    dialect.find_plan(ReturningProbeSpec::Item).sql.should eq(
      %(SELECT "id", "name", "version" FROM "probe_items" WHERE "id" = $1)
    )
    dialect.insert_plan(ReturningProbeSpec::Item).should eq(
      LF::Data::SQL::InsertPlan.new(
        %(INSERT INTO "probe_items" ("name", "version") VALUES ($1, $2) RETURNING "id"),
        LF::Data::SQL::GeneratedKeySource::ReturningRow,
        "id"
      )
    )
    dialect.update_plan(ReturningProbeSpec::Item).sql.should eq(
      %(UPDATE "probe_items" SET "name" = $1, "version" = "version" + 1 WHERE "id" = $2 AND "version" = $3)
    )
    dialect.delete_plan(ReturningProbeSpec::Item).sql.should eq(
      %(DELETE FROM "probe_items" WHERE "id" = $1 AND "version" = $2)
    )
  end

  it "specializes the same entity differently for SQLite" do
    returning_sql = ReturningProbeSpec::Dialect.new.insert_plan(ReturningProbeSpec::Item).sql
    sqlite_sql = LF::Data::Dialects::SQLite.new.insert_plan(ReturningProbeSpec::Item).sql

    returning_sql.should_not eq(sqlite_sql)
    sqlite_sql.should eq(%(INSERT INTO "probe_items" ("name", "version") VALUES (?, ?)))
  end

  it "numbers static SELECT predicates and pagination in bind order" do
    dialect : LF::Data::Dialect = ReturningProbeSpec::Dialect.new
    fields = ReturningProbeSpec::Item::Fields
    predicate = fields.name.eq("opal").and(fields.version.gte(2_i64))

    sql = dialect.select_plan(
      ReturningProbeSpec::Item,
      LF::Data::Query::Rows(
        LF::Data::Query::SelectQuery(
          ReturningProbeSpec::Item,
          typeof(predicate),
          LF::Data::Query::NoOrdering,
          LF::Data::Query::WithLimit,
          LF::Data::Query::WithOffset,
        ),
      )
    ).sql

    sql.should eq(
      %(SELECT "id", "name", "version" FROM "probe_items" ) +
      %(WHERE ("name" = $1) AND ("version" >= $2) LIMIT $3 OFFSET $4)
    )
  end

  it "numbers bulk DML placeholders in argument bind order" do
    dialect : LF::Data::Dialect = ReturningProbeSpec::Dialect.new
    fields = ReturningProbeSpec::Item::Fields
    predicate = fields.version.eq(2_i64)

    update_sql = dialect.update_query_plan(
      ReturningProbeSpec::Item,
      LF::Data::Query::UpdateQuery(
        ReturningProbeSpec::Item,
        Tuple(typeof(fields.name)),
        Tuple(String),
        typeof(predicate),
      )
    ).sql
    delete_sql = dialect.delete_query_plan(
      ReturningProbeSpec::Item,
      LF::Data::Query::DeleteQuery(
        ReturningProbeSpec::Item,
        typeof(predicate),
      )
    ).sql

    update_sql.should eq(
      %(UPDATE "probe_items" SET "name" = $1 WHERE "version" = $2)
    )
    delete_sql.should eq(
      %(DELETE FROM "probe_items" WHERE "version" = $1)
    )
  end

  it "numbers dynamic SELECT placeholders in runtime bind order" do
    fields = ReturningProbeSpec::Item::Fields
    predicate = fields.name.eq("opal").and(fields.version.gte(2_i64))
    predicates = [] of LF::Data::Query::DynamicPredicateNode(ReturningProbeSpec::Item)
    predicates << LF::Data::Query::TypedDynamicPredicateNode(
      ReturningProbeSpec::Item,
      typeof(predicate),
    ).new(predicate)

    rendered = LF::Data::Query::DynamicRenderer(ReturningProbeSpec::Item).new(
      ReturningProbeSpec::Dialect.new
    ).build(
      predicates,
      [] of LF::Data::Query::DynamicOrderNode(ReturningProbeSpec::Item),
      10_i64,
      3_i64,
      LF::Data::Query::DynamicTerminal::Rows
    )

    rendered.sql.should eq(
      %(SELECT "id", "name", "version" FROM "probe_items" ) +
      %(WHERE (("name" = $1) AND ("version" >= $2)) LIMIT $3 OFFSET $4)
    )
    rendered.arguments.should eq(
      ["opal", 2_i64, 10_i64, 3_i64] of DB::Any
    )
  end
end
