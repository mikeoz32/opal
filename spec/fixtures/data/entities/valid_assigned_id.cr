require "../../../../src/opal/data"

class ValidAssignedIdEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : String

  getter payload : Bytes

  def initialize(@id : String, @payload : Bytes)
  end
end

entity = ValidAssignedIdEntity.new("assigned", Bytes[1, 2])
raise "constructor changed" unless entity.id == "assigned"
raise "entity marker missing" unless ValidAssignedIdEntity.__lf_entity?
