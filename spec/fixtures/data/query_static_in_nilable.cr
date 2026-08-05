require "../../../src/opal/data"

class QueryStaticInNilableFixture
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64
  getter note : String?

  def initialize(@id, @note)
  end
end

value = nil.as(String?)
QueryStaticInNilableFixture::Fields.note.in({value})
