require "../../../../src/opal/data"

class NilableVersionEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::Version]
  getter version : Int64? = nil

  def initialize(@id : Int64)
  end
end
