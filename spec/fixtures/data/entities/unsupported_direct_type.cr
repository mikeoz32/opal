require "../../../../src/opal/data"

struct UnsupportedMoney
  getter cents : Int64

  def initialize(@cents : Int64)
  end
end

class UnsupportedDirectTypeEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  getter amount : UnsupportedMoney

  def initialize(@id : Int64, @amount : UnsupportedMoney)
  end
end
