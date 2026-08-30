require "json"
require "opal"
require "opal/autoconfig/data"
require "opal/autoconfig/http"
require "sqlite3"
require "./migrations"

module TodoTimeAsString
  extend self

  def load(result : DB::ResultSet) : Time
    Time.parse_rfc3339(result.read(String))
  end

  def dump(value : Time) : String
    value.to_utc.to_rfc3339
  end
end

@[LF::Data::Table("todos")]
class Todo
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  property title : String
  property completed : Bool

  @[LF::Data::Column(converter: TodoTimeAsString)]
  getter created_at : Time

  @[LF::Data::Version]
  getter version : Int64 = 0_i64

  def initialize(
    @title : String,
    @completed : Bool = false,
    @created_at : Time = Time.utc,
  )
    @id = nil
  end
end

@[LF::Data::Table("todo_audits")]
class TodoAudit
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  getter todo_id : Int64
  getter action : String

  @[LF::Data::Column(converter: TodoTimeAsString)]
  getter created_at : Time

  def initialize(
    @todo_id : Int64,
    @action : String,
    @created_at : Time = Time.utc,
  )
    @id = nil
  end
end

class TodoAuditFailure < Exception
end

@[LF::DI::Service]
class TodoRepository
  def all(manager : LF::Data::EntityManager) : Array(Todo)
    manager.repository(Todo).query.order_by(Todo::Fields.id.desc).to_a
  end

  def find(manager : LF::Data::EntityManager, id : Int64) : Todo?
    manager.repository(Todo).find(id)
  end

  def create(manager : LF::Data::EntityManager, title : String) : Todo
    todo = Todo.new(title)
    manager.repository(Todo).persist(todo)
    manager.flush
    todo
  end

  def update(
    manager : LF::Data::EntityManager,
    id : Int64,
    title : String?,
    completed : Bool?,
  ) : Todo?
    repository = manager.repository(Todo)
    todo = repository.find(id)
    return nil unless todo

    changed = false
    if value = title
      todo.title = value
      changed = true
    end
    unless completed.nil?
      todo.completed = completed
      changed = true
    end
    if changed
      repository.persist(todo)
      manager.flush
    end
    todo
  end

  def delete(manager : LF::Data::EntityManager, id : Int64) : Bool
    manager.repository(Todo).delete(id)
  end
end

@[LF::DI::Service]
class TodoAuditRepository
  def record(
    manager : LF::Data::EntityManager,
    todo_id : Int64,
    action : String,
  ) : TodoAudit
    audit = TodoAudit.new(todo_id, action)
    manager.repository(TodoAudit).persist(audit)
    audit
  end

  def for_todo(
    manager : LF::Data::EntityManager,
    todo_id : Int64,
  ) : Array(TodoAudit)
    manager.repository(TodoAudit).query
      .where(TodoAudit::Fields.todo_id.eq(todo_id))
      .order_by(TodoAudit::Fields.id.asc)
      .to_a
  end
end

@[LF::DI::Service]
class TodoService
  def initialize(
    @data_source : LF::Data::DataSource,
    @todo_repository : TodoRepository,
    @audit_repository : TodoAuditRepository,
  )
  end

  def all : Array(Todo)
    @data_source.transaction { |manager| @todo_repository.all(manager) }
  end

  def find(id : Int64) : Todo?
    @data_source.transaction { |manager| @todo_repository.find(manager, id) }
  end

  def create(title : String) : Todo
    @data_source.transaction do |manager|
      todo = @todo_repository.create(manager, title)
      @audit_repository.record(manager, todo.id.not_nil!, "created")
      todo
    end
  end

  def create_then_fail(title : String) : Nil
    @data_source.transaction do |manager|
      todo = @todo_repository.create(manager, title)
      @audit_repository.record(manager, todo.id.not_nil!, "created")
      manager.flush
      raise TodoAuditFailure.new("forced failure after todo and audit writes")
    end
  end

  def update(id : Int64, title : String?, completed : Bool?) : Todo?
    @data_source.transaction do |manager|
      todo = @todo_repository.update(manager, id, title, completed)
      if todo
        @audit_repository.record(manager, todo.id.not_nil!, "updated")
      end
      todo
    end
  end

  def delete(id : Int64) : Bool
    @data_source.transaction do |manager|
      deleted = @todo_repository.delete(manager, id)
      @audit_repository.record(manager, id, "deleted") if deleted
      deleted
    end
  end

  def audits(id : Int64) : Array(TodoAudit)
    @data_source.transaction do |manager|
      @audit_repository.for_todo(manager, id)
    end
  end
end

class CreateTodoPayload
  include JSON::Serializable

  property title : String
end

class UpdateTodoPayload
  include JSON::Serializable

  property title : String?
  property completed : Bool?
end

class TodoResponse
  include JSON::Serializable

  property id : Int64
  property title : String
  property completed : Bool
  property created_at : String
  property version : Int64

  def initialize(todo : Todo)
    @id = todo.id.not_nil!
    @title = todo.title
    @completed = todo.completed
    @created_at = todo.created_at.to_utc.to_rfc3339
    @version = todo.version
  end
end

class TodoListResponse
  include JSON::Serializable

  property todos : Array(TodoResponse)

  def initialize(todos : Array(Todo))
    @todos = todos.map { |todo| TodoResponse.new(todo) }
  end
end

class TodoApi
  include LF::HTTP::Controller

  def initialize(@todo_service : TodoService)
  end

  @[LF::HTTP::Controller::Get("/todos")]
  def index : TodoListResponse
    TodoListResponse.new(@todo_service.all)
  end

  @[LF::HTTP::Controller::Get("/todos/:id")]
  def show(id : Int64) : TodoResponse
    todo = @todo_service.find(id)
    raise LF::HTTP::NotFound.new("Todo not found") unless todo
    TodoResponse.new(todo)
  end

  @[LF::HTTP::Controller::Post("/todos")]
  def create(payload : CreateTodoPayload) : TodoResponse
    TodoResponse.new(@todo_service.create(payload.title))
  end

  @[LF::HTTP::Controller::Put("/todos/:id")]
  def update(id : Int64, payload : UpdateTodoPayload) : TodoResponse
    todo = @todo_service.update(id, payload.title, payload.completed)
    raise LF::HTTP::NotFound.new("Todo not found") unless todo
    TodoResponse.new(todo)
  end

  @[LF::HTTP::Controller::Delete("/todos/:id")]
  def destroy(id : Int64) : LF::HTTP::Response
    deleted = @todo_service.delete(id)
    raise LF::HTTP::NotFound.new("Todo not found") unless deleted
    LF::HTTP::TextResponse.create("deleted")
  end
end

@[LF::ApplicationConfiguration]
class TodoDataConfiguration
  @[LF::DI::Bean]
  def migration_set : LF::Data::MigrationSet
    TodoMigrations.build
  end
end

@[LF::Application]
@[LF::AutoConfig::Data]
@[LF::AutoConfig::HTTP]
class TodoApplication
end
