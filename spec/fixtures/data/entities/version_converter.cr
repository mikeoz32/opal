require "../../../../src/opal/data"

module VersionConverter
  def self.load(result : DB::ResultSet) : Int64
    result.read(Int64)
  end

  def self.dump(value : Int64) : Int64
    value
  end
end

class VersionConverterEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::Version]
  @[LF::Data::Column(converter: VersionConverter)]
  getter version : Int64 = 0_i64

  def initialize(@id : Int64)
  end
end
