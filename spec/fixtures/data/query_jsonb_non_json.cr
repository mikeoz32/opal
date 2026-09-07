require "../../../src/opal/data"

class NonJSONBQueryEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  getter title : String

  def initialize(@id, @title)
  end
end

NonJSONBQueryEntity::Fields.title.jsonb_has_key("status")
