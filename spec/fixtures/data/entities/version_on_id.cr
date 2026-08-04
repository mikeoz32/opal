require "../../../../src/opal/data"

class VersionOnIdEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  @[LF::Data::Version]
  getter id : Int64 = 0_i64
end
