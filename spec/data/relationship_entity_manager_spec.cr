require "./spec_helper"
require "../../src/opal/data"
require "../../src/opal/data/dialects/sqlite"
require "./support/sqlite_database"

@[LF::Data::Table("relationship_projects")]
private class RelationshipProject
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  property name : String

  @[LF::Data::HasMany(
    foreign_key: "project_id",
    cascade_persist: true,
    cascade_remove: true,
  )]
  getter tasks : Array(RelationshipTask) = [] of RelationshipTask

  @[LF::Data::HasOne(
    foreign_key: "project_id",
    cascade_persist: true,
    cascade_remove: true,
  )]
  property profile : RelationshipProfile?

  @[LF::Data::Version]
  getter version : Int64 = 0_i64

  def initialize(@name : String)
    @id = nil
    @profile = nil
  end
end

@[LF::Data::Table("relationship_tasks")]
private class RelationshipTask
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  getter project_id : Int64?
  property title : String

  @[LF::Data::BelongsTo(
    foreign_key: "project_id",
    cascade_persist: true,
  )]
  property project : RelationshipProject?

  @[LF::Data::Version]
  getter version : Int64 = 0_i64

  def initialize(@title : String, @project : RelationshipProject? = nil)
    @id = nil
    @project_id = nil
  end
end

@[LF::Data::Table("relationship_profiles")]
private class RelationshipProfile
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  getter project_id : Int64?
  property label : String

  @[LF::Data::BelongsTo(foreign_key: "project_id")]
  property project : RelationshipProject?

  def initialize(@label : String, @project : RelationshipProject? = nil)
    @id = nil
    @project_id = nil
  end
end

@[LF::Data::Table("relationship_uncascaded_tasks")]
private class RelationshipUncascadedTask
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  getter project_id : Int64?
  getter title : String

  @[LF::Data::BelongsTo(foreign_key: "project_id")]
  property project : RelationshipProject?

  def initialize(@title : String, @project : RelationshipProject? = nil)
    @id = nil
    @project_id = nil
  end
end

@[LF::Data::Table("relationship_cycle_left")]
private class RelationshipCycleLeft
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : String

  getter right_id : String

  @[LF::Data::BelongsTo(foreign_key: "right_id")]
  property right : RelationshipCycleRight?

  def initialize(@id : String, @right_id : String)
    @right = nil
  end
end

@[LF::Data::Table("relationship_cycle_right")]
private class RelationshipCycleRight
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : String

  getter left_id : String

  @[LF::Data::BelongsTo(foreign_key: "left_id")]
  property left : RelationshipCycleLeft?

  def initialize(@id : String, @left_id : String)
    @left = nil
  end
end

private class RelationshipListener
  include LF::Data::Listener

  getter statements = [] of LF::Data::StatementCompletionEvent

  def on_statement_completion(event : LF::Data::StatementCompletionEvent) : Nil
    @statements << event
  end
end

private def prepare_relationship_tables(database : DB::Database) : Nil
  database.exec(
    "CREATE TABLE relationship_projects (" \
    "id INTEGER PRIMARY KEY AUTOINCREMENT, " \
    "name TEXT NOT NULL, version INTEGER NOT NULL DEFAULT 0)"
  )
  database.exec(
    "CREATE TABLE relationship_tasks (" \
    "id INTEGER PRIMARY KEY AUTOINCREMENT, " \
    "project_id INTEGER NOT NULL, title TEXT NOT NULL, " \
    "version INTEGER NOT NULL DEFAULT 0, " \
    "FOREIGN KEY (project_id) REFERENCES relationship_projects(id))"
  )
  database.exec(
    "CREATE TABLE relationship_profiles (" \
    "id INTEGER PRIMARY KEY AUTOINCREMENT, " \
    "project_id INTEGER NOT NULL UNIQUE, label TEXT NOT NULL, " \
    "FOREIGN KEY (project_id) REFERENCES relationship_projects(id))"
  )
  database.exec(
    "CREATE TABLE relationship_uncascaded_tasks (" \
    "id INTEGER PRIMARY KEY AUTOINCREMENT, " \
    "project_id INTEGER NOT NULL, title TEXT NOT NULL, " \
    "FOREIGN KEY (project_id) REFERENCES relationship_projects(id))"
  )
end

private def relationship_graph(name : String = "project")
  project = RelationshipProject.new(name)
  first = RelationshipTask.new("first", project)
  second = RelationshipTask.new("second", project)
  profile = RelationshipProfile.new("profile", project)
  project.tasks << first << second
  project.profile = profile
  {project, first, second, profile}
end

private def with_relationship_source(&block)
  LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
    prepare_relationship_tables(database)
    listener = RelationshipListener.new
    source = LF::Data::DataSource.new(
      database,
      dialect: LF::Data::Dialects::SQLite.new,
      listeners: [listener] of LF::Data::Listener
    )
    yield database, source, listener
  end
end

describe "EntityManager relationships" do
  it "cascades inserts, propagates generated foreign keys, and preserves dependency order" do
    with_relationship_source do |database, source, listener|
      project, first, second, profile = relationship_graph

      source.transaction do |manager|
        manager.persist(project)
        manager.flush
      end

      project.id.should_not be_nil
      first.project_id.should eq(project.id)
      second.project_id.should eq(project.id)
      profile.project_id.should eq(project.id)
      listener.statements.reject(&.operation.select?).map(&.entity_name).should eq([
        "RelationshipProject",
        "RelationshipTask",
        "RelationshipTask",
        "RelationshipProfile",
      ])
      database.scalar("SELECT count(*) FROM relationship_projects").should eq(1_i64)
      database.scalar("SELECT count(*) FROM relationship_tasks").should eq(2_i64)
      database.scalar("SELECT count(*) FROM relationship_profiles").should eq(1_i64)
    end
  end

  it "cascades belongs_to persist without recursing through the inverse collection" do
    with_relationship_source do |database, source, listener|
      project = RelationshipProject.new("parent")
      task = RelationshipTask.new("child", project)

      source.transaction { |manager| manager.persist(task) }

      task.project_id.should eq(project.id)
      listener.statements.reject(&.operation.select?).map(&.entity_name).should eq([
        "RelationshipProject",
        "RelationshipTask",
      ])
    end
  end

  it "keeps relationship loading explicit" do
    with_relationship_source do |database, source, listener|
      project, _, _, _ = relationship_graph
      source.transaction { |manager| manager.persist(project) }
      listener.statements.clear

      loaded = source.transaction do |manager|
        manager.find(RelationshipProject, project.id.not_nil!).not_nil!
      end

      loaded.tasks.should be_empty
      loaded.profile.should be_nil
      listener.statements.map(&.operation).should eq([
        LF::Data::StatementOperation::Select,
      ])
    end
  end

  it "cascades deletes only across explicitly loaded relationships" do
    with_relationship_source do |database, source, listener|
      project, _, _, _ = relationship_graph
      source.transaction { |manager| manager.persist(project) }
      listener.statements.clear

      source.transaction do |manager|
        loaded = manager.find(RelationshipProject, project.id.not_nil!).not_nil!
        tasks = manager.query(RelationshipTask)
          .where(RelationshipTask::Fields.project_id.eq(project.id.not_nil!))
          .to_a
        profile = manager.query(RelationshipProfile)
          .where(RelationshipProfile::Fields.project_id.eq(project.id.not_nil!))
          .first?
        loaded.tasks.concat(tasks)
        loaded.profile = profile
        manager.remove(loaded)
      end

      writes = listener.statements.reject(&.operation.select?)
      writes.map(&.entity_name).should eq([
        "RelationshipTask",
        "RelationshipTask",
        "RelationshipProfile",
        "RelationshipProject",
      ])
      database.scalar("SELECT count(*) FROM relationship_tasks").should eq(0_i64)
      database.scalar("SELECT count(*) FROM relationship_profiles").should eq(0_i64)
      database.scalar("SELECT count(*) FROM relationship_projects").should eq(0_i64)
    end
  end

  it "does not interpret collection removal as orphan deletion" do
    with_relationship_source do |database, source, listener|
      project, _, _, _ = relationship_graph
      source.transaction { |manager| manager.persist(project) }

      source.transaction do |manager|
        loaded = manager.find(RelationshipProject, project.id.not_nil!).not_nil!
        loaded.tasks.concat(
          manager.query(RelationshipTask)
            .where(RelationshipTask::Fields.project_id.eq(project.id.not_nil!))
            .to_a
        )
        loaded.tasks.pop
        manager.persist(loaded)
      end

      database.scalar("SELECT count(*) FROM relationship_tasks").should eq(2_i64)
    end
  end

  it "rejects an uncascaded unsaved target before inserting the dependent row" do
    with_relationship_source do |database, source, listener|
      project = RelationshipProject.new("unsaved")
      task = RelationshipUncascadedTask.new("child", project)

      error = expect_raises(LF::Data::UnsavedRelationshipError) do
        source.transaction { |manager| manager.persist(task) }
      end

      error.entity_name.should eq("RelationshipUncascadedTask")
      error.relationship.should eq("project")
      listener.statements.should be_empty
      database.scalar("SELECT count(*) FROM relationship_projects").should eq(0_i64)
      database.scalar("SELECT count(*) FROM relationship_uncascaded_tasks").should eq(0_i64)
    end
  end

  it "rejects a relationship object that conflicts with its scalar foreign key" do
    with_relationship_source do |database, source, listener|
      first_project, _, _, _ = relationship_graph("first")
      second_project = RelationshipProject.new("second")
      source.transaction do |manager|
        manager.persist(first_project)
        manager.persist(second_project)
      end
      listener.statements.clear

      error = expect_raises(LF::Data::RelationshipKeyMismatchError) do
        source.transaction do |manager|
          task = manager.query(RelationshipTask)
            .where(RelationshipTask::Fields.project_id.eq(first_project.id.not_nil!))
            .first?
            .not_nil!
          target = manager.find(RelationshipProject, second_project.id.not_nil!).not_nil!
          task.project = target
          manager.persist(task)
        end
      end

      error.entity_name.should eq("RelationshipTask")
      error.relationship.should eq("project")
      error.foreign_key.should eq("project_id")
      listener.statements.reject(&.operation.select?).should be_empty
    end
  end

  it "detects relationship cycles before executing SQL" do
    with_relationship_source do |database, source, listener|
      left = RelationshipCycleLeft.new("left", "right")
      right = RelationshipCycleRight.new("right", "left")
      left.right = right
      right.left = left

      error = expect_raises(LF::Data::RelationshipCycleError) do
        source.transaction do |manager|
          manager.persist(left)
          manager.persist(right)
        end
      end

      error.entities.should contain("RelationshipCycleLeft")
      error.entities.should contain("RelationshipCycleRight")
      listener.statements.should be_empty
    end
  end

  it "rejects cascade remove for an unmanaged child" do
    with_relationship_source do |database, source, listener|
      project, _, _, _ = relationship_graph
      source.transaction { |manager| manager.persist(project) }

      expect_raises(LF::Data::UnmanagedRelationshipError) do
        source.transaction do |manager|
          loaded = manager.find(RelationshipProject, project.id.not_nil!).not_nil!
          loaded.tasks << RelationshipTask.new("not loaded", loaded)
          manager.remove(loaded)
        end
      end

      database.scalar("SELECT count(*) FROM relationship_projects").should eq(1_i64)
      database.scalar("SELECT count(*) FROM relationship_tasks").should eq(2_i64)
    end
  end

  it "rolls back cascaded optimistic deletes when one child is stale" do
    with_relationship_source do |database, source, listener|
      project, _, _, _ = relationship_graph
      source.transaction { |manager| manager.persist(project) }

      error = expect_raises(LF::Data::OptimisticLockError) do
        source.transaction do |manager|
          loaded = manager.find(RelationshipProject, project.id.not_nil!).not_nil!
          loaded.tasks.concat(
            manager.query(RelationshipTask)
              .where(RelationshipTask::Fields.project_id.eq(project.id.not_nil!))
              .to_a
          )
          manager.connection.exec(
            "UPDATE relationship_tasks SET version = version + 1 WHERE id = ?",
            loaded.tasks.first.id
          )
          manager.remove(loaded)
        end
      end

      error.entity_name.should eq("RelationshipTask")
      database.scalar("SELECT count(*) FROM relationship_projects").should eq(1_i64)
      database.scalar("SELECT count(*) FROM relationship_tasks").should eq(2_i64)
      database.scalar("SELECT max(version) FROM relationship_tasks").should eq(0_i64)
    end
  end
end

describe "relationship metadata" do
  it "exposes typed descriptors without a runtime registry" do
    belongs_to = RelationshipTask::Relations.project
    belongs_to.name.should eq("project")
    belongs_to.kind.belongs_to?.should be_true
    belongs_to.target_type.should eq(RelationshipProject)
    belongs_to.foreign_key_property.should eq("project_id")
    belongs_to.cascade_persist?.should be_true
    belongs_to.cascade_remove?.should be_false

    has_many = RelationshipProject::Relations.tasks
    has_many.kind.has_many?.should be_true
    has_many.target_type.should eq(RelationshipTask)
    has_many.cascade_persist?.should be_true
    has_many.cascade_remove?.should be_true
  end

  it "turns relation descriptors into explicit foreign-key schema metadata" do
    model = LF::Data::Schema::Model.build do |schema|
      schema.table("relationship_projects") do |table|
        table.generated_id("id")
        table.string("name", null: false)
      end
      schema.table("relationship_tasks") do |table|
        table.generated_id("id")
        table.int64("project_id", null: false)
        table.string("title", null: false)
        table.foreign_key(
          RelationshipTask::Relations.project,
          name: "fk_relationship_tasks_project"
        )
      end
      schema.table("relationship_profiles") do |table|
        table.generated_id("id")
        table.int64("project_id", null: false)
        table.string("label", null: false)
        table.foreign_key(RelationshipProject::Relations.profile)
      end
    end

    task_table = model.table("relationship_tasks").not_nil!
    task_foreign_key = task_table.foreign_keys.first
    task_foreign_key.local_columns.should eq(["project_id"])
    task_foreign_key.referenced_table.should eq("relationship_projects")
    task_foreign_key.referenced_columns.should eq(["id"])
    task_foreign_key.name.should eq("fk_relationship_tasks_project")

    profile_table = model.table("relationship_profiles").not_nil!
    profile_table.foreign_keys.first.local_columns.should eq(["project_id"])
    profile_table.unique_constraints.first.columns.should eq(["project_id"])
  end

  it "rejects applying a relation descriptor to the wrong table" do
    expect_raises(ArgumentError, /defines a foreign key on/) do
      LF::Data::Schema::Model.build do |schema|
        schema.table("relationship_projects") do |table|
          table.generated_id("id")
          table.foreign_key(RelationshipTask::Relations.project)
        end
      end
    end
  end
end
