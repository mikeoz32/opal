require "../../../src/opal/data"
require "../../../src/opal/data/dialects/sqlite"

class CrossPredicateLeft
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  def initialize(@id)
  end
end

class CrossPredicateRight
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  def initialize(@id)
  end
end

predicate = CrossPredicateRight::Fields.id.eq(1_i64)
LF::Data::Dialects::SQLite.new.select_plan(
  CrossPredicateLeft,
  LF::Data::Query::Rows(
    LF::Data::Query::SelectQuery(
      CrossPredicateLeft,
      typeof(predicate),
      LF::Data::Query::NoOrdering,
      LF::Data::Query::NoLimit,
      LF::Data::Query::NoOffset,
    ),
  )
)
