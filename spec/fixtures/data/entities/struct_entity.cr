require "../../../../src/opal/data"

struct StructEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  def initialize(@id : Int64)
  end
end
