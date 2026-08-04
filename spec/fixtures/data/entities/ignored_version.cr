require "../../../../src/opal/data"

class IgnoredVersionEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::Version]
  @[LF::Data::Column(ignore: true)]
  getter version : Int64 = 0_i64

  def initialize(@id : Int64)
  end
end
