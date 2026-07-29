require "../spec_helper"
require "../../../src/opal/data"

module StaticPlanCompilerSpec
  @[LF::Data::Table("order]items")]
  class Item
    @[LF::Data::Id]
    getter id : Int64

    @[LF::Data::Column(name: "display]name")]
    getter name : String

    def initialize(@id, @name)
    end
  end

  class Dialect < LF::Data::Dialect
    module StaticSQLPolicy
      IDENTIFIER_OPEN        = "["
      IDENTIFIER_CLOSE       = "]"
      IDENTIFIER_ESCAPE_FROM = "]"
      IDENTIFIER_ESCAPE_TO   = "]]"
      PLACEHOLDER_STYLE      = :anonymous
      PLACEHOLDER_TOKEN      = "@p"
      EMPTY_INSERT_STYLE     = :default_values
      GENERATED_KEY_SOURCE   = LF::Data::SQL::GeneratedKeySource::LastInsertId
    end

    STATIC_SQL_POLICY = StaticSQLPolicy
    include LF::Data::SQL::StaticPlanCompiler

    def name : String
      "static-plan-probe"
    end

    def quote_identifier(identifier : String) : String
      "[#{identifier.gsub("]", "]]")}]"
    end

    def placeholder(position : Int32) : String
      "@p"
    end

    def supports?(capability : LF::Data::DialectCapability) : Bool
      capability.last_insert_id?
    end
  end
end

describe LF::Data::SQL::StaticPlanCompiler do
  it "applies the including dialect policy to common CRUD SQL" do
    dialect = StaticPlanCompilerSpec::Dialect.new

    dialect.quote_identifier("order]items").should eq("[order]]items]")
    dialect.placeholder(3).should eq("@p")
    dialect.find_plan(StaticPlanCompilerSpec::Item).sql.should eq(
      "SELECT [id], [display]]name] FROM [order]]items] WHERE [id] = @p"
    )
    dialect.insert_plan(StaticPlanCompilerSpec::Item).should eq(
      LF::Data::SQL::InsertPlan.new(
        "INSERT INTO [order]]items] ([id], [display]]name]) VALUES (@p, @p)",
        LF::Data::SQL::GeneratedKeySource::None,
        nil
      )
    )
    dialect.update_plan(StaticPlanCompilerSpec::Item).sql.should eq(
      "UPDATE [order]]items] SET [display]]name] = @p WHERE [id] = @p"
    )
    dialect.delete_plan(StaticPlanCompilerSpec::Item).sql.should eq(
      "DELETE FROM [order]]items] WHERE [id] = @p"
    )
  end

  it "rejects an incomplete policy with the concrete dialect name" do
    fixture = File.expand_path("../../fixtures/data/incomplete_static_sql_policy.cr", __DIR__)
    result = LF::DataSpecSupport.compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain("IncompleteStaticSQLPolicyDialect")
    result[:error].should contain("PLACEHOLDER_TOKEN")
  end

  it "rejects an unsupported placeholder style" do
    fixture = File.expand_path("../../fixtures/data/unsupported_static_sql_policy.cr", __DIR__)
    result = LF::DataSpecSupport.compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain("UnsupportedStaticSQLPolicyDialect")
    result[:error].should contain("unsupported PLACEHOLDER_STYLE")
  end

  it "rejects invalid static table and column identifiers" do
    {
      "empty_static_table_name.cr",
      "nul_static_column_name.cr",
    }.each do |fixture_name|
      fixture = File.expand_path("../../fixtures/data/#{fixture_name}", __DIR__)
      result = LF::DataSpecSupport.compile_fixture(fixture)

      result[:status].success?.should be_false
      result[:error].should contain("Invalid SQL identifier")
      result[:error].should contain("InvalidStaticIdentifierDialect")
    end
  end

  it "rejects unsupported insert policy values independent of entity shape" do
    {
      "unsupported_empty_insert_style.cr"   => "EMPTY_INSERT_STYLE",
      "unsupported_generated_key_source.cr" => "generated key source",
      "fractional_placeholder_position.cr"  => "PLACEHOLDER_FIRST_POSITION",
      "spoofed_generated_key_source.cr"     => "generated key source",
    }.each do |fixture_name, expected_error|
      fixture = File.expand_path("../../fixtures/data/#{fixture_name}", __DIR__)
      result = LF::DataSpecSupport.compile_fixture(fixture)

      result[:status].success?.should be_false
      result[:error].should contain(expected_error)
    end
  end
end
