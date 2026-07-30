require "../../../src/opal/data"

class QueryNilNonNilEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  def initialize(@id : Int64)
  end
end

QueryNilNonNilEntity::Fields.id.is_nil
