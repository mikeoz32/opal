require "../../../src/opal/data"

class GeneratedRepositoryEntity
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  def initialize
    @id = nil
  end
end

class OtherRepositoryEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : String

  def initialize(@id : String)
  end
end

manager = nil.as(LF::Data::EntityManager?).not_nil!
manager.repository(GeneratedRepositoryEntity).persist(
  OtherRepositoryEntity.new("other")
)
