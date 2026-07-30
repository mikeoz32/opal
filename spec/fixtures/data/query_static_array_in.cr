require "../../../src/opal/data"

class QueryStaticArrayInFixture
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  def initialize(@id)
  end
end

QueryStaticArrayInFixture::Fields.id.in([1_i64, 2_i64])
