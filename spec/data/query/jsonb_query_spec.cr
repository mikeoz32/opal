require "../spec_helper"
require "../../../src/opal/data/dialects/postgresql"
require "../../../src/opal/data/dialects/sqlite"

struct JSONBQueryDocument
  include JSON::Serializable

  getter status : String
  getter tags : Array(String)

  def initialize(@status : String, @tags : Array(String))
  end
end

@[LF::Data::Table("jsonb_query_records")]
private class JSONBQueryRecord
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::Column(type: :jsonb)]
  getter payload : JSONBQueryDocument

  def initialize(@id, @payload)
  end
end

private def jsonb_static_plan(predicate : P) forall P
  LF::Data::Dialects::PostgreSQL.new.select_plan(
    JSONBQueryRecord,
    LF::Data::Query::Rows(
      LF::Data::Query::SelectQuery(
        JSONBQueryRecord,
        P,
        LF::Data::Query::NoOrdering,
        LF::Data::Query::NoLimit,
        LF::Data::Query::NoOffset,
      ),
    )
  )
end

private def jsonb_dynamic_render(
  dialect : LF::Data::Dialect,
  predicate : P,
) forall P
  node = LF::Data::Query::TypedDynamicPredicateNode(JSONBQueryRecord, P).new(predicate)
  LF::Data::Query::DynamicRenderer(JSONBQueryRecord).new(dialect).build(
    [node] of LF::Data::Query::DynamicPredicateNode(JSONBQueryRecord),
    [] of LF::Data::Query::DynamicOrderNode(JSONBQueryRecord),
    nil,
    nil,
    LF::Data::Query::DynamicTerminal::Rows
  )
end

describe "typed PostgreSQL JSONB predicates" do
  fields = JSONBQueryRecord::Fields

  it "compiles containment, contained-by, and key predicates statically" do
    contains = fields.payload.jsonb_contains({status: "open"})
    contained_by = fields.payload.jsonb_contained_by(
      JSONBQueryDocument.new("open", ["release"])
    )
    has_key = fields.payload.jsonb_has_key("status")
    predicate = contains.and(contained_by).and(has_key)

    plan = jsonb_static_plan(predicate)
    plan.sql.should eq(
      %(SELECT "id", "payload" FROM "jsonb_query_records" ) +
      %(WHERE (("payload" @> $1) AND ("payload" <@ $2)) AND ("payload" ? $3))
    )
    predicate.__lf_args.should eq({
      %({"status":"open"}),
      %({"status":"open","tags":["release"]}),
      "status",
    })
  end

  it "renders the same operators for dynamic PostgreSQL queries" do
    rendered = jsonb_dynamic_render(
      LF::Data::Dialects::PostgreSQL.new,
      fields.payload.jsonb_contains({tags: ["release"]})
    )

    rendered.sql.should end_with(%(WHERE ("payload" @> $1)))
    rendered.arguments.should eq([%({"tags":["release"]})] of DB::Any)
  end

  it "raises a typed dialect error for dynamic SQLite queries" do
    error = expect_raises(LF::Data::UnsupportedQueryOperatorError) do
      jsonb_dynamic_render(
        LF::Data::Dialects::SQLite.new,
        fields.payload.jsonb_has_key("status")
      )
    end

    error.dialect.should eq("sqlite")
    error.operator.should eq(:has_key)
  end

  it "rejects NUL in JSONB keys before rendering" do
    expect_raises(LF::Data::InvalidPredicateError, /NUL/) do
      fields.payload.jsonb_has_key("bad\0key")
    end
  end
end
