require "../../../src/opal/data"

class QueryNilOrderFixture
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64
  getter note : String?

  def initialize(@id, @note)
  end
end

QueryNilOrderFixture::Fields.note.lt(nil)
