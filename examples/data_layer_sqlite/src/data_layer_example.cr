require "opal/data"
require "opal/data/dialects/sqlite"

module DataLayerExample
  module TimeAsString
    extend self

    def load(result : DB::ResultSet) : Time
      Time.parse_rfc3339(result.read(String))
    end

    def dump(value : Time) : String
      value.to_utc.to_rfc3339
    end
  end

  @[LF::Data::Table("showcase_projects")]
  class Project
    include LF::Data::Entity

    @[LF::Data::Id(generated: true)]
    getter id : Int64?

    getter name : String

    @[LF::Data::Column(converter: TimeAsString)]
    getter created_at : Time

    @[LF::Data::HasMany(
      foreign_key: "project_id",
      cascade_persist: true,
      cascade_remove: true,
    )]
    getter tasks : Array(Task) = [] of Task

    @[LF::Data::HasOne(
      foreign_key: "project_id",
      cascade_persist: true,
      cascade_remove: true,
    )]
    property profile : ProjectProfile?

    def initialize(@name : String, @created_at : Time = Time.utc)
      @id = nil
      @profile = nil
    end
  end

  @[LF::Data::Table("showcase_tasks")]
  class Task
    include LF::Data::Entity

    @[LF::Data::Id(generated: true)]
    getter id : Int64?

    getter project_id : Int64?

    @[LF::Data::Column(name: "task_title")]
    property title : String

    property completed : Bool
    property due_at : Time?

    @[LF::Data::Column(converter: TimeAsString)]
    getter created_at : Time

    @[LF::Data::Version]
    getter version : Int64 = 0_i64

    @[LF::Data::Column(ignore: true)]
    getter display_label : String = "hydrated"

    @[LF::Data::BelongsTo(
      foreign_key: "project_id",
      cascade_persist: true,
    )]
    property project : Project?

    @[LF::Data::HasMany(
      foreign_key: "task_id",
      cascade_persist: true,
      cascade_remove: true,
    )]
    getter events : Array(TaskEvent) = [] of TaskEvent

    def initialize(
      @project_id : Int64,
      @title : String,
      @completed : Bool = false,
      @due_at : Time? = nil,
      @created_at : Time = Time.utc,
    )
      @id = nil
      @project = nil
    end

    def initialize(
      @project : Project,
      @title : String,
      @completed : Bool = false,
      @due_at : Time? = nil,
      @created_at : Time = Time.utc,
    )
      @id = nil
      @project_id = nil
    end
  end

  @[LF::Data::Table("showcase_task_events")]
  class TaskEvent
    include LF::Data::Entity

    @[LF::Data::Id(generated: true)]
    getter id : Int64?

    getter task_id : Int64?
    getter kind : String

    @[LF::Data::BelongsTo(
      foreign_key: "task_id",
      cascade_persist: true,
    )]
    property task : Task?

    def initialize(@task_id : Int64, @kind : String)
      @id = nil
      @task = nil
    end

    def initialize(@task : Task, @kind : String)
      @id = nil
      @task_id = nil
    end
  end

  @[LF::Data::Table("showcase_project_profiles")]
  class ProjectProfile
    include LF::Data::Entity

    @[LF::Data::Id(generated: true)]
    getter id : Int64?

    getter project_id : Int64?
    property label : String

    @[LF::Data::BelongsTo(foreign_key: "project_id")]
    property project : Project?

    def initialize(@project : Project, @label : String)
      @id = nil
      @project_id = nil
    end
  end

  class CreateProjects < LF::Data::Migration
    def version : Int64
      1_i64
    end

    def name : String
      "create_showcase_projects"
    end

    def up(schema : LF::Data::SchemaEditor) : Nil
      schema.create_table("showcase_projects") do |table|
        table.generated_id("id")
        table.string("name", null: false)
        table.timestamp("created_at", null: false)
        table.unique("name", name: "uq_showcase_projects_name")
      end
    end
  end

  class CreateTasks < LF::Data::Migration
    def version : Int64
      2_i64
    end

    def name : String
      "create_showcase_tasks"
    end

    def up(schema : LF::Data::SchemaEditor) : Nil
      schema.create_table("showcase_tasks") do |table|
        table.generated_id("id")
        table.int64("project_id", null: false)
        table.string("task_title", null: false)
        table.bool("completed", null: false, default: false)
        table.timestamp("due_at")
        table.timestamp("created_at", null: false)
        table.int64("version", null: false, default: 0_i64)
        table.foreign_key(
          Task::Relations.project,
          name: "fk_showcase_tasks_project"
        )
        table.index("idx_showcase_tasks_project", "project_id")
      end
    end
  end

  class CreateTaskEvents < LF::Data::Migration
    def version : Int64
      3_i64
    end

    def name : String
      "create_showcase_task_events"
    end

    def up(schema : LF::Data::SchemaEditor) : Nil
      schema.create_table("showcase_task_events") do |table|
        table.generated_id("id")
        table.int64("task_id", null: false)
        table.string("kind", null: false)
        table.foreign_key(
          Task::Relations.events,
          name: "fk_showcase_task_events_task"
        )
      end
    end
  end

  class CreateProjectProfiles < LF::Data::Migration
    def version : Int64
      4_i64
    end

    def name : String
      "create_showcase_project_profiles"
    end

    def up(schema : LF::Data::SchemaEditor) : Nil
      schema.create_table("showcase_project_profiles") do |table|
        table.generated_id("id")
        table.int64("project_id", null: false)
        table.string("label", null: false)
        table.foreign_key(
          Project::Relations.profile,
          name: "fk_showcase_project_profiles_project"
        )
      end
    end
  end

  module Migrations
    extend self

    def build : LF::Data::MigrationSet
      LF::Data::MigrationSet.new(
        CreateProjects.new,
        CreateTasks.new,
        CreateTaskEvents.new,
        CreateProjectProfiles.new
      )
    end
  end

  class TraceListener
    include LF::Data::Listener

    getter transaction_outcomes = [] of LF::Data::TransactionOutcome
    getter statements = [] of LF::Data::StatementCompletionEvent

    def on_transaction_completion(event : LF::Data::TransactionCompletionEvent) : Nil
      @transaction_outcomes << event.outcome
    end

    def on_statement_completion(event : LF::Data::StatementCompletionEvent) : Nil
      @statements << event
    end
  end

  class Store
    getter source : LF::Data::DataSource

    def self.open(
      url : String,
      listeners : Enumerable(LF::Data::Listener)? = nil,
    ) : self
      new(
        LF::Data::DataSource.open(
          url,
          dialect: LF::Data::Dialects::SQLite.new,
          listeners: listeners
        )
      )
    end

    def initialize(@source : LF::Data::DataSource)
    end

    def migrate : Nil
      LF::Data::MigrationRunner.new(@source).run(Migrations.build)
    end

    def close : Nil
      @source.close
    end
  end
end
