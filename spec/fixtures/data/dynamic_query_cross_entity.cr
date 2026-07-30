require "../../../src/opal/data"
require "../../../src/opal/data/dialects/sqlite"

class DynamicCrossLeft
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  def initialize(@id)
  end
end

class DynamicCrossRight
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  def initialize(@id)
  end
end

expression = DynamicCrossRight::Fields.id.eq(1_i64)
predicates = [] of LF::Data::Query::DynamicPredicateNode(DynamicCrossLeft)
predicates << LF::Data::Query::TypedDynamicPredicateNode(
  DynamicCrossLeft,
  typeof(expression),
).new(expression)

LF::Data::Query::DynamicRenderer(DynamicCrossLeft).new(
  LF::Data::Dialects::SQLite.new
).build(
  predicates,
  [] of LF::Data::Query::DynamicOrderNode(DynamicCrossLeft),
  nil,
  nil,
  LF::Data::Query::DynamicTerminal::Rows
)
