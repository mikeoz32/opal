require "../spec_helper"
require "../../../src/opal/data/dialects/postgresql"

module PostgreSQLDialectSpec
  @[LF::Data::Table("projects")]
  class Project
    include LF::Data::Entity

    @[LF::Data::Id(generated: true)]
    getter id : Int64?

    getter name : String

    @[LF::Data::Version]
    getter version : Int64 = 0_i64

    def initialize(@name : String)
      @id = nil
    end
  end
end

describe LF::Data::Dialects::PostgreSQL do
  dialect = LF::Data::Dialects::PostgreSQL.new

  it "owns PostgreSQL identifiers, placeholders, and capabilities" do
    dialect.name.should eq("postgresql")
    dialect.quote_identifier(%(project"events)).should eq(%("project""events"))
    dialect.placeholder(3).should eq("$3")
    dialect.offset_without_limit("$4").should eq("OFFSET $4")

    dialect.supports?(LF::Data::DialectCapability::ReturningRow).should be_true
    dialect.supports?(LF::Data::DialectCapability::TransactionalDDL).should be_true
    dialect.supports?(LF::Data::DialectCapability::MigrationLock).should be_true
    dialect.supports?(LF::Data::DialectCapability::LastInsertId).should be_false
  end

  it "compiles generated CRUD with RETURNING and numbered binds" do
    dialect.find_plan(PostgreSQLDialectSpec::Project).sql.should eq(
      %(SELECT "id", "name", "version" FROM "projects" WHERE "id" = $1)
    )
    dialect.insert_plan(PostgreSQLDialectSpec::Project).should eq(
      LF::Data::SQL::InsertPlan.new(
        %(INSERT INTO "projects" ("name", "version") VALUES ($1, $2) RETURNING "id"),
        LF::Data::SQL::GeneratedKeySource::ReturningRow,
        "id"
      )
    )
    dialect.update_plan(PostgreSQLDialectSpec::Project).sql.should eq(
      %(UPDATE "projects" SET "name" = $1, "version" = "version" + 1 WHERE "id" = $2 AND "version" = $3)
    )
    dialect.delete_plan(PostgreSQLDialectSpec::Project).sql.should eq(
      %(DELETE FROM "projects" WHERE "id" = $1 AND "version" = $2)
    )
  end

  it "numbers dynamic predicates and pagination in bind order" do
    fields = PostgreSQLDialectSpec::Project::Fields
    predicate = fields.name.eq("opal").and(fields.version.gte(2_i64))
    predicates = [] of LF::Data::Query::DynamicPredicateNode(PostgreSQLDialectSpec::Project)
    predicates << LF::Data::Query::TypedDynamicPredicateNode(
      PostgreSQLDialectSpec::Project,
      typeof(predicate),
    ).new(predicate)

    rendered = LF::Data::Query::DynamicRenderer(PostgreSQLDialectSpec::Project).new(
      dialect
    ).build(
      predicates,
      [] of LF::Data::Query::DynamicOrderNode(PostgreSQLDialectSpec::Project),
      10_i64,
      3_i64,
      LF::Data::Query::DynamicTerminal::Rows
    )

    rendered.sql.should eq(
      %(SELECT "id", "name", "version" FROM "projects" ) +
      %(WHERE (("name" = $1) AND ("version" >= $2)) LIMIT $3 OFFSET $4)
    )
    rendered.arguments.should eq(
      ["opal", 2_i64, 10_i64, 3_i64] of DB::Any
    )
  end
end
