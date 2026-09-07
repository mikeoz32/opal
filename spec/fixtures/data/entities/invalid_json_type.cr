require "../../../../src/opal/data"

class InvalidJSONTypeEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::Column(type: :document)]
  getter payload : String

  def initialize(@id, @payload)
  end
end
