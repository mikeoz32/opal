require "../../../src/opal/data"

class QueryOrderBoolFixture
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  getter active : Bool

  def initialize(@id, @active)
  end
end

QueryOrderBoolFixture::Fields.active.lt(true)
