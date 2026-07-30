require "../../../src/opal/data"

class QueryLikeNonStringEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  def initialize(@id : Int64)
  end
end

QueryLikeNonStringEntity::Fields.id.like("%wrong%")
