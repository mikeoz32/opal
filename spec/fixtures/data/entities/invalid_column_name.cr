require "../../../../src/opal/data"

class InvalidColumnNameEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::Column(name: "")]
  getter payload : String

  def initialize(@id : Int64, @payload : String)
  end
end
