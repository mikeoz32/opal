require "json"
require "opal/http/app"
require "sqlite3"
require "./data_layer_example_transport"

module DataLayerExample
  module Web
    class API
      def initialize(@store : Store)
      end

      def setup_routes(router : LF::HTTP::Router) : Nil
        router.get("/health") do |context, _params|
          context.response.content_type = "application/json"
          context.response.print %({"status":"ok"})
        end

        router.get("/projects") do |context, _params|
          projects = @store.source.read do |manager|
            manager.query(Project).order_by(Project::Fields.name.asc).to_a
          end
          write_json(context, ProjectListResponse.new(projects.map { |project| ProjectResponse.new(project) }))
        end

        router.post("/projects") do |context, _params|
          payload = parse_body(context, CreateProjectRequest)
          project = with_conflict_handling do
            @store.source.transaction do |manager|
              if manager.query(Project)
                   .where(Project::Fields.name.eq(payload.name))
                   .first?
                raise Conflict.new("A project with that name already exists")
              end

              created_project = Project.new(payload.name)
              manager.persist(created_project)
              manager.flush
              created_project
            end
          end
          write_json(context, ProjectResponse.new(project))
        end

        router.get("/projects/:project_id/tasks") do |context, params|
          project_id = parse_id(params, "project_id")
          tasks = @store.source.read do |manager|
            unless manager.find(Project, project_id)
              raise LF::HTTP::NotFound.new("Project not found")
            end

            manager.query(Task)
              .where(Task::Fields.project_id.eq(project_id))
              .order_by(Task::Fields.id.asc)
              .to_a
          end
          write_json(context, TaskListResponse.new(tasks.map { |task| TaskResponse.new(task) }))
        end

        router.post("/projects/:project_id/tasks") do |context, params|
          project_id = parse_id(params, "project_id")
          payload = parse_body(context, CreateTaskRequest)
          task = @store.source.transaction do |manager|
            unless manager.find(Project, project_id)
              raise LF::HTTP::NotFound.new("Project not found")
            end

            created_task = Task.new(project_id, payload.title)
            manager.persist(created_task)
            manager.flush
            created_task
          end
          write_json(context, TaskResponse.new(task))
        end

        router.patch("/tasks/:task_id") do |context, params|
          task_id = parse_id(params, "task_id")
          payload = parse_body(context, UpdateTaskRequest)
          if payload.title.nil? && payload.completed.nil?
            raise LF::HTTP::BadRequest.new("At least one task field is required")
          end
          task = with_conflict_handling do
            @store.source.transaction do |manager|
              found_task = manager.find(Task, task_id)
              raise LF::HTTP::NotFound.new("Task not found") unless found_task

              if title = payload.title
                found_task.title = title
              end
              if completed = payload.completed
                found_task.completed = completed
              end
              manager.persist(found_task)
              found_task
            end
          end
          write_json(context, TaskResponse.new(task))
        end

        router.delete("/tasks/:task_id") do |context, params|
          task_id = parse_id(params, "task_id")
          @store.source.transaction do |manager|
            found_task = manager.find(Task, task_id)
            raise LF::HTTP::NotFound.new("Task not found") unless found_task

            manager.query(TaskEvent)
              .where(TaskEvent::Fields.task_id.eq(task_id))
              .to_a.each { |event| manager.remove(event) }
            manager.remove(found_task)
          end
          context.response.content_type = "text/plain"
          context.response.print "deleted"
        end
      end

      private def parse_id(params : Hash(String, String), name : String) : Int64
        value = params[name]?
        raise LF::HTTP::BadRequest.new("Missing required path parameter '#{name}'") unless value
        value.to_i64?
          .try { |id| return id }
        raise LF::HTTP::BadRequest.new("Invalid #{name}")
      end

      private def with_conflict_handling(& : -> T) : T forall T
        yield
      rescue error : LF::Data::OptimisticLockError
        raise Conflict.new("Record was modified concurrently")
      rescue error : SQLite3::Exception
        if error.message.try(&.includes?("UNIQUE constraint failed"))
          raise Conflict.new("A project with that name already exists")
        end
        raise error
      end

      private def parse_body(context : HTTP::Server::Context, type : T.class) : T forall T
        body = context.request.body
        raise LF::HTTP::BadRequest.new("Missing request body") unless body
        T.from_json(body)
      rescue error : JSON::SerializableError | JSON::ParseException
        raise LF::HTTP::BadRequest.new(error.message || "Invalid JSON request body")
      end

      private def write_json(
        context : HTTP::Server::Context,
        payload : JSON::Serializable,
        status : HTTP::Status = HTTP::Status::OK,
      ) : Nil
        context.response.status = status
        context.response.content_type = "application/json"
        payload.to_json(context.response)
      end
    end

    def self.build_app(store : Store) : LF::HTTP::App
      api = API.new(store)
      LF::HTTP::App.new do |router|
        api.setup_routes(router)
      end
    end
  end
end
