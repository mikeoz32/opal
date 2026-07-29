require "../../../../src/opal/data"

class InvalidGeneratedIdEntity
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : String?

  def initialize
    @id = nil
  end
end
