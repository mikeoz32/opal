require "json"
require "opal"
require "opal/autoconfig/data"
require "opal/autoconfig/http"
require "sqlite3"
require "./data_layer_example_transport"

module DataLayerExample
  @[LF::ApplicationConfiguration]
  class DataConfiguration
    @[LF::DI::Bean]
    def migration_set : LF::Data::MigrationSet
      Migrations.build
    end
  end

  class HealthResponse
    include JSON::Serializable

    property status : String

    def initialize(@status : String)
    end
  end

  class ApplicationAPI
    include LF::HTTP::Controller

    def initialize(@data_source : LF::Data::DataSource)
    end

    @[LF::HTTP::Controller::Get("/health")]
    def health : HealthResponse
      HealthResponse.new("ok")
    end

    @[LF::HTTP::Controller::Get("/projects")]
    def projects
      @data_source.read do |manager|
        projects = manager.query(Project).order_by(Project::Fields.name.asc).to_a
        Web::ProjectListResponse.new(projects.map { |project| Web::ProjectResponse.new(project) })
      end
    end

    @[LF::HTTP::Controller::Post("/projects")]
    def create_project(payload : Web::CreateProjectRequest)
      project = with_conflict_handling do
        @data_source.transaction do |manager|
          if manager.query(Project).where(Project::Fields.name.eq(payload.name)).first?
            raise Web::Conflict.new("A project with that name already exists")
          end

          created_project = Project.new(payload.name)
          manager.persist(created_project)
          manager.flush
          created_project
        end
      end
      Web::ProjectResponse.new(project)
    end

    @[LF::HTTP::Controller::Get("/projects/:project_id/tasks")]
    def tasks(project_id : Int64)
      @data_source.read do |manager|
        raise LF::HTTP::NotFound.new("Project not found") unless manager.find(Project, project_id)

        tasks = manager.query(Task)
          .where(Task::Fields.project_id.eq(project_id))
          .order_by(Task::Fields.id.asc)
          .to_a
        Web::TaskListResponse.new(tasks.map { |task| Web::TaskResponse.new(task) })
      end
    end

    @[LF::HTTP::Controller::Post("/projects/:project_id/tasks")]
    def create_task(project_id : Int64, payload : Web::CreateTaskRequest)
      task = @data_source.transaction do |manager|
        raise LF::HTTP::NotFound.new("Project not found") unless manager.find(Project, project_id)

        created_task = Task.new(project_id, payload.title)
        manager.persist(created_task)
        manager.flush
        created_task
      end
      Web::TaskResponse.new(task)
    end

    @[LF::HTTP::Controller::Patch("/tasks/:task_id")]
    def update_task(task_id : Int64, payload : Web::UpdateTaskRequest)
      if payload.title.nil? && payload.completed.nil?
        raise LF::HTTP::BadRequest.new("At least one task field is required")
      end

      task = with_conflict_handling do
        @data_source.transaction do |manager|
          found_task = manager.find(Task, task_id)
          raise LF::HTTP::NotFound.new("Task not found") unless found_task

          if title = payload.title
            found_task.title = title
          end
          found_task.completed = payload.completed.as(Bool) unless payload.completed.nil?
          manager.persist(found_task)
          found_task
        end
      end
      Web::TaskResponse.new(task)
    end

    @[LF::HTTP::Controller::Delete("/tasks/:task_id")]
    def delete_task(task_id : Int64) : String
      @data_source.transaction do |manager|
        found_task = manager.find(Task, task_id)
        raise LF::HTTP::NotFound.new("Task not found") unless found_task

        manager.query(TaskEvent)
          .where(TaskEvent::Fields.task_id.eq(task_id))
          .to_a.each { |event| manager.remove(event) }
        manager.remove(found_task)
      end
      "deleted"
    end

    private def with_conflict_handling(& : -> T) : T forall T
      yield
    rescue error : LF::Data::OptimisticLockError
      raise Web::Conflict.new("Record was modified concurrently")
    rescue error : SQLite3::Exception
      if error.message.try(&.includes?("UNIQUE constraint failed"))
        raise Web::Conflict.new("A project with that name already exists")
      end
      raise error
    end
  end
end
