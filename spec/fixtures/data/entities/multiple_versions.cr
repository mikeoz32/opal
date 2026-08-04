require "../../../../src/opal/data"

class MultipleVersionsEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::Version]
  getter first_version : Int64 = 0_i64

  @[LF::Data::Version]
  getter second_version : Int64 = 0_i64

  def initialize(@id : Int64)
  end
end
