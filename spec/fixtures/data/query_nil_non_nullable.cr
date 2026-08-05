require "../../../src/opal/data"

class QueryNilNonNullableFixture
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  def initialize(@id)
  end
end

QueryNilNonNullableFixture::Fields.id.eq(nil)
