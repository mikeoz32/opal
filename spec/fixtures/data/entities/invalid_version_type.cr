require "../../../../src/opal/data"

class InvalidVersionTypeEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::Version]
  getter version : Int32

  def initialize(@id : Int64, @version : Int32 = 0)
  end
end
