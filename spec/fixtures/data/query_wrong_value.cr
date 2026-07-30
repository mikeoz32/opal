require "../../../src/opal/data"

class QueryWrongValueEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  def initialize(@id : Int64)
  end
end

QueryWrongValueEntity::Fields.id.eq("wrong")
