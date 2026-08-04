require "../../../../src/opal/data"

class VersionWithoutDefaultEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::Version]
  getter version : Int64

  def initialize(@id : Int64, @version : Int64)
  end
end
