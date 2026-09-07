require "../../../../src/opal/data"

class JSONIdEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  @[LF::Data::Column(type: :jsonb)]
  getter id : String

  def initialize(@id)
  end
end
