require "../../../src/opal/data"

class QueryStaticInNilFixture
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64
  getter note : String?

  def initialize(@id, @note)
  end
end

QueryStaticInNilFixture::Fields.note.in({nil, "value"})
