require "../../../../src/opal/data"

class MissingIdEntity
  include LF::Data::Entity

  getter title : String

  def initialize(@title : String)
  end
end
