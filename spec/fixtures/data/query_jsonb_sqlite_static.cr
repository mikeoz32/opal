require "../../../src/opal/data"
require "../../../src/opal/data/dialects/sqlite"

struct SQLiteJSONBDocument
  include JSON::Serializable

  getter status : String

  def initialize(@status)
  end
end

class SQLiteJSONBQueryEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::Column(type: :jsonb)]
  getter payload : SQLiteJSONBDocument

  def initialize(@id, @payload)
  end
end

predicate = SQLiteJSONBQueryEntity::Fields.payload.jsonb_contains({status: "open"})
LF::Data::Dialects::SQLite.new.select_plan(
  SQLiteJSONBQueryEntity,
  LF::Data::Query::Rows(
    LF::Data::Query::SelectQuery(
      SQLiteJSONBQueryEntity,
      typeof(predicate),
      LF::Data::Query::NoOrdering,
      LF::Data::Query::NoLimit,
      LF::Data::Query::NoOffset,
    ),
  )
)
