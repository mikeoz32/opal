require "../spec_helper"
require "../../../src/opal/data"

private module ExpressionTitleConverter
  class_getter dumps = 0

  def self.load(result : DB::ResultSet) : String
    result.read(String)
  end

  def self.dump(value : String) : String
    @@dumps += 1
    value.downcase
  end
end

private class ExpressionEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::Column(converter: ExpressionTitleConverter)]
  getter title : String

  getter active : Bool
  getter score : Int32
  getter note : String?

  def initialize(
    @id : Int64,
    @title : String,
    @active : Bool,
    @score : Int32,
    @note : String?,
  )
  end
end

private def nullable_expression_value(value : String?) : String?
  value
end

describe LF::Data::Query do
  it "builds typed comparison predicates with dumped arguments" do
    dumps = ExpressionTitleConverter.dumps

    expression = ExpressionEntity::Fields.title.eq("Mixed")

    expression.__lf_args.should eq({"mixed"})
    ExpressionTitleConverter.dumps.should eq(dumps + 1)
    typeof(expression).should_not eq(
      typeof(ExpressionEntity::Fields.id.eq(1_i64))
    )
  end

  it "builds every ordered comparison" do
    field = ExpressionEntity::Fields.score

    field.ne(1).__lf_args.should eq({1})
    field.lt(2).__lf_args.should eq({2})
    field.lte(3).__lf_args.should eq({3})
    field.gt(4).__lf_args.should eq({4})
    field.gte(5).__lf_args.should eq({5})
  end

  it "builds fixed-arity and empty IN predicates" do
    values = ExpressionEntity::Fields.id.in({1_i64, 2_i64, 3_i64})
    empty = ExpressionEntity::Fields.id.in(Tuple.new)

    values.__lf_args.should eq({1_i64, 2_i64, 3_i64})
    empty.__lf_args.should eq(Tuple.new)
    typeof(values).should_not eq(typeof(empty))
  end

  it "builds nil and string predicates only on compatible fields" do
    equal_nil = ExpressionEntity::Fields.note.eq(nil)
    not_equal_nil = ExpressionEntity::Fields.note.ne(nil)

    typeof(equal_nil).should eq(
      typeof(ExpressionEntity::Fields.note.is_nil)
    )
    typeof(not_equal_nil).should eq(
      typeof(ExpressionEntity::Fields.note.is_not_nil)
    )
    equal_nil.__lf_args.should eq(Tuple.new)
    not_equal_nil.__lf_args.should eq(Tuple.new)
    ExpressionEntity::Fields.note.is_nil.__lf_args.should eq(Tuple.new)
    ExpressionEntity::Fields.note.is_not_nil.__lf_args.should eq(Tuple.new)
    ExpressionEntity::Fields.title.like("%Opal%").__lf_args.should eq({"%opal%"})
  end

  it "rejects nilable runtime values instead of generating NULL comparisons" do
    optional = nullable_expression_value(nil)

    ExpressionEntity::Fields.note.eq(optional).__lf_args.should eq(Tuple.new)
    ExpressionEntity::Fields.note.ne(optional).__lf_args.should eq(Tuple.new)
    runtime = nullable_expression_value("runtime")
    ExpressionEntity::Fields.note.eq(runtime).__lf_args.should eq({"runtime"})
    ExpressionEntity::Fields.note.ne(runtime).__lf_args.should eq({"runtime"})
  end

  it "rejects NULL values in ordered and IN predicates at runtime or compile time" do
    expect_raises(LF::Data::InvalidPredicateError) do
      ExpressionEntity::Fields.note.in(["value", nil] of String?)
    end
  end

  it "composes argument order depth-first" do
    left = ExpressionEntity::Fields.active.eq(false)
    middle = ExpressionEntity::Fields.title.like("%Opal%")
    right = ExpressionEntity::Fields.score.gte(10)

    expression = left.and(middle.or(right)).not

    expression.__lf_args.should eq({false, "%opal%", 10})
  end

  it "stores no SQL or runtime field names in expression objects" do
    expression = ExpressionEntity::Fields.title.eq("value")
    source = File.read(
      File.expand_path("../../../src/opal/data/query/expression.cr", __DIR__)
    )

    expression.value.should eq("value")
    source.should_not contain("@field")
    source.should_not contain("@column")
    source.should_not contain("@sql")
  end
end
