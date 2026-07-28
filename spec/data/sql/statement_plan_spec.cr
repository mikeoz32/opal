require "../../spec_helper"
require "../../../src/opal/data"

@[LF::Data::Table("todos")]
class StatementPlanTodo
  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  @[LF::Data::Column(name: "summary")]
  getter title : String

  @[LF::Data::Column(ignore: true)]
  getter display_label : String

  @[LF::Data::Version]
  getter version : Int64

  def initialize(@id, @title, @display_label, @version)
  end
end

describe "Data SQL plans" do
  it "stores only final SQL in a statement plan" do
    plan = LF::Data::SQL::StatementPlan.new("select 1")

    plan.sql.should eq("select 1")
    plan.responds_to?(:sql=).should be_false
  end

  it "stores generated key behavior in an insert plan" do
    plan = LF::Data::SQL::InsertPlan.new(
      "insert into todos (summary) values (?)",
      LF::Data::SQL::GeneratedKeySource::LastInsertId,
      "id"
    )

    plan.sql.should contain("insert into")
    plan.generated_key_source.should eq(LF::Data::SQL::GeneratedKeySource::LastInsertId)
    plan.generated_column.should eq("id")
    plan.responds_to?(:sql=).should be_false
  end

  it "accepts mapping annotations without installing runtime behavior" do
    StatementPlanTodo.responds_to?(:table).should be_false
    StatementPlanTodo.responds_to?(:persist).should be_false
  end
end
