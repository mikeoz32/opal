require "../../../../src/opal/data"

class ValidVersionEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::Version]
  getter version : Int64 = 0_i64

  def initialize(@id : Int64)
  end
end
