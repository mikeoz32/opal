require "../../../../src/opal/data"

class MultipleIdsEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter tenant_id : Int64

  @[LF::Data::Id]
  getter record_id : Int64

  def initialize(@tenant_id : Int64, @record_id : Int64)
  end
end
