require "../../../../src/opal/data"

class WritableVersionEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::Version]
  property version : Int64

  def initialize(@id : Int64, @version : Int64 = 0)
  end
end
