require "../spec_helper"
require "../../../src/opal/data/dialects/sqlite"
require "sqlite3"

@[LF::Data::Table("todos")]
class SQLiteDialectTodo
  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  @[LF::Data::Column(name: "summary")]
  getter title : String

  getter completed : Bool

  @[LF::Data::Column(ignore: true)]
  getter display_label : String

  @[LF::Data::Version]
  getter version : Int64

  def initialize(@id, @title, @completed, @display_label, @version)
  end
end

@[LF::Data::Table("assigned_todos")]
class SQLiteAssignedTodo
  @[LF::Data::Id]
  getter id : Int64

  def initialize(@id)
  end
end

@[LF::Data::Table("only_ids")]
class SQLiteOnlyId
  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  def initialize(@id)
  end
end

@[LF::Data::Table("reserved\"todos")]
class SQLiteReservedTodo
  @[LF::Data::Id]
  @[LF::Data::Column(name: "select\"value")]
  getter id : Int64

  def initialize(@id)
  end
end

describe "SQLite dialect" do
  it "quotes identifiers and exposes SQLite capabilities" do
    dialect = LF::Data::Dialects::SQLite.new

    dialect.name.should eq("sqlite")
    dialect.quote_identifier("select\"value").should eq(%("select""value"))
    dialect.placeholder(4).should eq("?")
    dialect.supports?(LF::Data::DialectCapability::LastInsertId).should be_true
    dialect.supports?(LF::Data::DialectCapability::ReturningRow).should be_false
    dialect.supports?(LF::Data::DialectCapability::MigrationLock).should be_true
    dialect.supports?(LF::Data::DialectCapability::SchemaInspection).should be_true
  end

  it "generates static CRUD SQL for a generated-id versioned entity" do
    dialect = LF::Data::Dialects::SQLite.new

    dialect.find_plan(SQLiteDialectTodo).sql.should eq(
      %(SELECT "id", "summary", "completed", "version" FROM "todos" WHERE "id" = ?)
    )
    dialect.insert_plan(SQLiteDialectTodo).should eq(
      LF::Data::SQL::InsertPlan.new(
        %(INSERT INTO "todos" ("summary", "completed", "version") VALUES (?, ?, ?)),
        LF::Data::SQL::GeneratedKeySource::LastInsertId,
        "id"
      )
    )
    dialect.update_plan(SQLiteDialectTodo).sql.should eq(
      %(UPDATE "todos" SET "summary" = ?, "completed" = ?, "version" = "version" + 1 WHERE "id" = ? AND "version" = ?)
    )
    dialect.delete_plan(SQLiteDialectTodo).sql.should eq(
      %(DELETE FROM "todos" WHERE "id" = ? AND "version" = ?)
    )
  end

  it "generates assigned-id and empty INSERT shapes" do
    dialect = LF::Data::Dialects::SQLite.new

    dialect.insert_plan(SQLiteAssignedTodo).should eq(
      LF::Data::SQL::InsertPlan.new(
        %(INSERT INTO "assigned_todos" ("id") VALUES (?)),
        LF::Data::SQL::GeneratedKeySource::None,
        nil
      )
    )
    dialect.insert_plan(SQLiteOnlyId).should eq(
      LF::Data::SQL::InsertPlan.new(
        %(INSERT INTO "only_ids" DEFAULT VALUES),
        LF::Data::SQL::GeneratedKeySource::LastInsertId,
        "id"
      )
    )
  end

  it "escapes reserved and quote-containing static identifiers" do
    dialect = LF::Data::Dialects::SQLite.new

    dialect.find_plan(SQLiteReservedTodo).sql.should eq(
      %(SELECT "select""value" FROM "reserved""todos" WHERE "select""value" = ?)
    )
  end

  it "does not require the sqlite driver from its opt-in dialect entrypoint" do
    fixture = File.expand_path("../../fixtures/data/sqlite_dialect_without_driver.cr", __DIR__)
    result = LF::DataSpecSupport.compile_fixture(fixture)

    result[:status].success?.should be_true
    result[:error].should eq("")
  end
end
