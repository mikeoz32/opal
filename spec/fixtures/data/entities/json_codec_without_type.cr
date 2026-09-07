require "../../../../src/opal/data"

module DetachedJSONCodec
end

class JSONCodecWithoutTypeEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::Column(codec: DetachedJSONCodec)]
  getter payload : String

  def initialize(@id, @payload)
  end
end
