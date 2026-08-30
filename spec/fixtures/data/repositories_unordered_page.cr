require "../../../src/opal/data"

class UnorderedRepositoryEntity
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  def initialize
    @id = nil
  end
end

manager = nil.as(LF::Data::EntityManager?).not_nil!
repository = manager.repository(UnorderedRepositoryEntity)
repository.page(repository.query, number: 1, size: 20)
