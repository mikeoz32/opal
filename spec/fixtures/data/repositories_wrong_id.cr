require "../../../src/opal/data"

class WrongRepositoryIDEntity
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  def initialize
    @id = nil
  end
end

manager = nil.as(LF::Data::EntityManager?).not_nil!
manager.repository(WrongRepositoryIDEntity).find("wrong")
