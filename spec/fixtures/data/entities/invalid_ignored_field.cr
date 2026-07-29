require "../../../../src/opal/data"

class InvalidIgnoredFieldEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  @[LF::Data::Column(ignore: true)]
  getter derived_label : String

  def initialize(@id : Int64, @derived_label : String)
  end
end
