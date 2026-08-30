require "../../../src/opal/data"

class GeneratedRepositoryEntity
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  getter name : String

  def initialize(@name : String)
    @id = nil
  end
end

class AssignedRepositoryEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : String

  def initialize(@id : String)
  end
end

manager = nil.as(LF::Data::EntityManager?).not_nil!
generated : LF::Data::Repository(GeneratedRepositoryEntity, Int64) = manager.repository(GeneratedRepositoryEntity)
assigned : LF::Data::Repository(AssignedRepositoryEntity, String) = manager.repository(AssignedRepositoryEntity)
generated_result : GeneratedRepositoryEntity? = generated.find(1_i64)
assigned_result : AssignedRepositoryEntity? = assigned.find("assigned")
