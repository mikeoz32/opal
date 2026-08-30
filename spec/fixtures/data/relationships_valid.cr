require "../../../src/opal/data"

@[LF::Data::Table("relationship_projects")]
class ValidRelationshipProject
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  getter name : String

  @[LF::Data::HasMany(
    foreign_key: "project_id",
    cascade_persist: true,
    cascade_remove: true,
  )]
  getter tasks : Array(ValidRelationshipTask) = [] of ValidRelationshipTask

  @[LF::Data::HasOne(
    foreign_key: "project_id",
    cascade_persist: true,
    cascade_remove: true,
  )]
  property profile : ValidRelationshipProfile?

  def initialize(@name : String)
    @id = nil
    @profile = nil
  end
end

@[LF::Data::Table("relationship_tasks")]
class ValidRelationshipTask
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  getter project_id : Int64?
  getter title : String

  @[LF::Data::BelongsTo(
    foreign_key: "project_id",
    cascade_persist: true,
  )]
  property project : ValidRelationshipProject?

  def initialize(@title : String, @project : ValidRelationshipProject? = nil)
    @id = nil
    @project_id = nil
  end
end

@[LF::Data::Table("relationship_profiles")]
class ValidRelationshipProfile
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  getter project_id : Int64?
  getter label : String

  @[LF::Data::BelongsTo(foreign_key: "project_id")]
  property project : ValidRelationshipProject?

  def initialize(@label : String, @project : ValidRelationshipProject? = nil)
    @id = nil
    @project_id = nil
  end
end

raise "belongs_to metadata mismatch" unless ValidRelationshipTask::Relations.project.kind.belongs_to?
raise "has_many metadata mismatch" unless ValidRelationshipProject::Relations.tasks.kind.has_many?
raise "has_one metadata mismatch" unless ValidRelationshipProject::Relations.profile.kind.has_one?

LF::Data::Schema::Model.build do |schema|
  schema.table("relationship_projects") do |table|
    table.generated_id("id")
    table.string("name", null: false)
  end
  schema.table("relationship_tasks") do |table|
    table.generated_id("id")
    table.int64("project_id")
    table.string("title", null: false)
    table.foreign_key(ValidRelationshipTask::Relations.project)
  end
  schema.table("relationship_profiles") do |table|
    table.generated_id("id")
    table.int64("project_id")
    table.string("label", null: false)
    table.foreign_key(ValidRelationshipProject::Relations.profile)
  end
end
