require "../../../../src/opal/data"

class NonzeroVersionDefaultEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::Version]
  getter version : Int64 = 1_i64

  def initialize(@id : Int64)
  end
end
