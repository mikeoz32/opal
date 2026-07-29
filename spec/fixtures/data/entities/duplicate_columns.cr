require "../../../../src/opal/data"

class DuplicateColumnsEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::Column(name: "value")]
  getter first : String

  @[LF::Data::Column(name: "value")]
  getter second : String

  def initialize(@id : Int64, @first : String, @second : String)
  end
end
