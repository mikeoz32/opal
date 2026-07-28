require "../spec_helper"
require "../../src/opal/data"

class DialectContractProbe < LF::Data::Dialect
  def name : String
    "probe"
  end

  def quote_identifier(identifier : String) : String
    "[#{identifier}]"
  end

  def placeholder(position : Int32) : String
    ":#{position}"
  end

  def find_plan(entity : T.class) : LF::Data::SQL::StatementPlan forall T
    LF::Data::SQL::StatementPlan.new("find")
  end

  def insert_plan(entity : T.class) : LF::Data::SQL::InsertPlan forall T
    LF::Data::SQL::InsertPlan.new(
      "insert",
      LF::Data::SQL::GeneratedKeySource::None,
      nil
    )
  end

  def update_plan(entity : T.class) : LF::Data::SQL::StatementPlan forall T
    LF::Data::SQL::StatementPlan.new("update")
  end

  def delete_plan(entity : T.class) : LF::Data::SQL::StatementPlan forall T
    LF::Data::SQL::StatementPlan.new("delete")
  end

  def supports?(capability : LF::Data::DialectCapability) : Bool
    capability == LF::Data::DialectCapability::ReturningRow
  end
end

describe "Data dialect contract" do
  it "dispatches generic plans through the abstract dialect type" do
    dialect : LF::Data::Dialect = DialectContractProbe.new

    dialect.find_plan(Int32).sql.should eq("find")
    dialect.insert_plan(String).generated_key_source.should eq(LF::Data::SQL::GeneratedKeySource::None)
    dialect.update_plan(Bool).sql.should eq("update")
    dialect.delete_plan(Float64).sql.should eq("delete")
  end

  it "keeps driver-neutral naming and placeholders in the base contract" do
    dialect = DialectContractProbe.new

    dialect.name.should eq("probe")
    dialect.quote_identifier("todos").should eq("[todos]")
    dialect.placeholder(2).should eq(":2")
  end

  it "exposes a closed capability set through supports?" do
    dialect = DialectContractProbe.new

    dialect.supports?(LF::Data::DialectCapability::ReturningRow).should be_true
    dialect.supports?(LF::Data::DialectCapability::LastInsertId).should be_false
  end
end
