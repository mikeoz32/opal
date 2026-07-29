require "../../../../src/opal/data"

@[LF::Data::Table("")]
class InvalidTableNameEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  def initialize(@id : Int64)
  end
end
