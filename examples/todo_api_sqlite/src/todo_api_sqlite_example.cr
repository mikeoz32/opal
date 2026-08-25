require "opal"
require "opal/autoconfig/http"
require "sqlite3"

class Todo
  include JSON::Serializable

  property id : Int64
  property title : String
  property completed : Bool
  property created_at : String

  def initialize(@id : Int64, @title : String, @completed : Bool, @created_at : String)
  end
end

class CreateTodoPayload
  include JSON::Serializable

  property title : String
end

class TodoListResponse
  include JSON::Serializable

  property todos : Array(Todo)

  def initialize(@todos : Array(Todo))
  end
end

class UpdateTodoPayload
  include JSON::Serializable

  property title : String?
  property completed : Bool?
end

@[LF::DI::Service]
class TodoDatabase
  include LF::DI::Initializable
  include LF::DI::Disposable

  getter db : DB::Database

  def initialize(config_service : LF::ConfigService)
    @db = DB.open(config_service.get("database.url", "sqlite3://./todo.db"))
  end

  def after_properties_set : Nil
    @db.exec <<-SQL
      CREATE TABLE IF NOT EXISTS todos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        completed INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL DEFAULT (datetime('now'))
      )
    SQL
  end

  def destroy : Nil
    @db.close
  end
end

@[LF::DI::Service]
class TodoRepository
  def initialize(todo_database : TodoDatabase)
    @db = todo_database.db
  end

  def all : Array(Todo)
    todos = [] of Todo
    @db.query("SELECT id, title, completed, created_at FROM todos ORDER BY id DESC") do |rs|
      rs.each do
        todos << Todo.new(
          id: rs.read(Int64),
          title: rs.read(String),
          completed: rs.read(Int64) == 1_i64,
          created_at: rs.read(String)
        )
      end
    end
    todos
  end

  def find(id : Int64) : Todo?
    @db.query_one?(
      "SELECT id, title, completed, created_at FROM todos WHERE id = ?",
      id,
      as: {Int64, String, Int64, String}
    ).try do |row|
      Todo.new(
        id: row[0],
        title: row[1],
        completed: row[2] == 1_i64,
        created_at: row[3]
      )
    end
  end

  def create(title : String) : Todo
    @db.exec("INSERT INTO todos (title, completed) VALUES (?, 0)", title)
    id = @db.scalar("SELECT last_insert_rowid()").as(Int64)
    find(id).not_nil!
  end

  def update(id : Int64, title : String?, completed : Bool?) : Todo?
    current = find(id)
    return nil unless current

    new_title = title || current.title
    new_completed = completed.nil? ? current.completed : completed

    @db.exec(
      "UPDATE todos SET title = ?, completed = ? WHERE id = ?",
      new_title,
      (new_completed ? 1 : 0),
      id
    )

    find(id)
  end

  def delete(id : Int64) : Bool
    @db.exec("DELETE FROM todos WHERE id = ?", id)
    @db.scalar("SELECT changes()").as(Int64) > 0
  end
end

class TodoApi
  include LF::HTTP::Controller

  def initialize(@todo_repository : TodoRepository)
  end

  @[LF::HTTP::Controller::Get("/todos")]
  def index
    TodoListResponse.new(@todo_repository.all)
  end

  @[LF::HTTP::Controller::Get("/todos/:id")]
  def show(id : Int64)
    todo = @todo_repository.find(id)
    raise LF::HTTP::NotFound.new("Todo not found") unless todo
    todo
  end

  @[LF::HTTP::Controller::Post("/todos")]
  def create(payload : CreateTodoPayload)
    @todo_repository.create(payload.title)
  end

  @[LF::HTTP::Controller::Put("/todos/:id")]
  def update(id : Int64, payload : UpdateTodoPayload)
    todo = @todo_repository.update(id, payload.title, payload.completed)
    raise LF::HTTP::NotFound.new("Todo not found") unless todo
    todo
  end

  @[LF::HTTP::Controller::Delete("/todos/:id")]
  def destroy(id : Int64)
    deleted = @todo_repository.delete(id)
    raise LF::HTTP::NotFound.new("Todo not found") unless deleted
    LF::HTTP::TextResponse.create("deleted")
  end
end

@[LF::Application]
@[LF::AutoConfig::HTTP]
class TodoApplication
end

TodoApplication.run_http
