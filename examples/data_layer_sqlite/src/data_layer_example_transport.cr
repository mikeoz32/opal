require "json"
require "opal/http/errors"
require "./data_layer_example"

module DataLayerExample
  module Web
    class Conflict < LF::HTTP::Error
      def initialize(message : String = "Conflict")
        super(message, HTTP::Status::CONFLICT)
      end
    end

    class CreateProjectRequest
      include JSON::Serializable

      property name : String
    end

    class CreateTaskRequest
      include JSON::Serializable

      property title : String
    end

    class UpdateTaskRequest
      include JSON::Serializable

      property title : String?
      property completed : Bool?
    end

    class ProjectResponse
      include JSON::Serializable

      property id : Int64
      property name : String
      property created_at : String

      def initialize(project : Project)
        @id = project.id.not_nil!
        @name = project.name
        @created_at = project.created_at.to_utc.to_rfc3339
      end
    end

    class ProjectListResponse
      include JSON::Serializable

      property projects : Array(ProjectResponse)

      def initialize(@projects : Array(ProjectResponse))
      end
    end

    class TaskResponse
      include JSON::Serializable

      property id : Int64
      property project_id : Int64
      property title : String
      property completed : Bool
      property due_at : String?
      property created_at : String
      property version : Int64

      def initialize(task : Task)
        @id = task.id.not_nil!
        @project_id = task.project_id
        @title = task.title
        @completed = task.completed
        @due_at = task.due_at.try(&.to_utc.to_rfc3339)
        @created_at = task.created_at.to_utc.to_rfc3339
        @version = task.version
      end
    end

    class TaskListResponse
      include JSON::Serializable

      property tasks : Array(TaskResponse)

      def initialize(@tasks : Array(TaskResponse))
      end
    end
  end
end
