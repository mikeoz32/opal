require "../../../../src/opal/data"

module ConflictingJSONConverter
end

module ConflictingJSONCodec
end

class JSONConverterAndCodecEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::Column(
    type: :jsonb,
    converter: ConflictingJSONConverter,
    codec: ConflictingJSONCodec,
  )]
  getter payload : String

  def initialize(@id, @payload)
  end
end
