require "../../../src/opal/data"
require "../../../src/opal/data/dialects/sqlite"

class CrossOrderLeft
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  def initialize(@id)
  end
end

class CrossOrderRight
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  def initialize(@id)
  end
end

LF::Data::Dialects::SQLite.new.select_plan(
  CrossOrderLeft,
  LF::Data::Query::Rows(
    LF::Data::Query::SelectQuery(
      CrossOrderLeft,
      LF::Data::Query::NoPredicate,
      LF::Data::Query::OrderList(
        LF::Data::Query::NoOrdering,
        typeof(CrossOrderRight::Fields.id.asc),
      ),
      LF::Data::Query::NoLimit,
      LF::Data::Query::NoOffset,
    ),
  )
)
