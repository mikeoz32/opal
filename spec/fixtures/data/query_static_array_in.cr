require "../../../src/opal/data"
require "../../../src/opal/data/dialects/sqlite"

class QueryStaticArrayInFixture
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  def initialize(@id)
  end
end

predicate = QueryStaticArrayInFixture::Fields.id.in([1_i64, 2_i64])
LF::Data::Dialects::SQLite.new.select_plan(
  QueryStaticArrayInFixture,
  LF::Data::Query::Rows(
    LF::Data::Query::SelectQuery(
      QueryStaticArrayInFixture,
      typeof(predicate),
      LF::Data::Query::NoOrdering,
      LF::Data::Query::NoLimit,
      LF::Data::Query::NoOffset,
    ),
  )
)
