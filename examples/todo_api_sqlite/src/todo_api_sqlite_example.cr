require "opal"
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

class TodoRepository
  def self.ensure_schema(db : DB::Database)
    db.exec <<-SQL
      CREATE TABLE IF NOT EXISTS todos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        completed INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL DEFAULT (datetime('now'))
      )
    SQL
  end

  def initialize(@db : DB::Database)
    self.class.ensure_schema(@db)
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
  include LF::APIRoute

  @[LF::APIRoute::Get("/todos")]
  def index(todo_repository : TodoRepository)
    LF::JSONResponse.create(TodoListResponse.new(todo_repository.all))
  end

  @[LF::APIRoute::Get("/todos/:id")]
  def show(id : Int64, todo_repository : TodoRepository)
    todo = todo_repository.find(id)
    raise LF::NotFound.new("Todo not found") unless todo
    LF::JSONResponse.create(todo)
  end

  @[LF::APIRoute::Post("/todos")]
  def create(payload : CreateTodoPayload, todo_repository : TodoRepository)
    LF::JSONResponse.create(todo_repository.create(payload.title))
  end

  @[LF::APIRoute::Put("/todos/:id")]
  def update(id : Int64, payload : UpdateTodoPayload, todo_repository : TodoRepository)
    todo = todo_repository.update(id, payload.title, payload.completed)
    raise LF::NotFound.new("Todo not found") unless todo
    LF::JSONResponse.create(todo)
  end

  @[LF::APIRoute::Delete("/todos/:id")]
  def destroy(id : Int64, todo_repository : TodoRepository)
    deleted = todo_repository.delete(id)
    raise LF::NotFound.new("Todo not found") unless deleted
    LF::TextResponse.create("deleted")
  end
end

class RequestScopeHandler
  include HTTP::Handler

  def initialize(@root : LF::DI::AnnotationApplicationContext)
  end

  def call(context)
    scope = @root.enter_scope("request")
    context.state = scope
    call_next(context)
  ensure
    scope.try(&.exit)
  end
end

db = DB.open("sqlite3://./todo.db")
TodoRepository.ensure_schema(db)

root = LF::DI::AnnotationApplicationContext.new
root.add_bean(name: "db", type: DB::Database) do |_ctx|
  db
end

root.add_bean(name: "todo_repository", scope: "request", type: TodoRepository) do |_ctx|
  TodoRepository.new(root.get_bean("db", DB::Database))
end

app = LF::LFApi.new do |router|
  TodoApi.new.setup_routes(router)
end

server = HTTP::Server.new([
  HTTP::LogHandler.new,
  RequestScopeHandler.new(root),
  app,
])

address = server.bind_tcp(8083)
puts "Todo API listening on http://#{address}"
puts "Routes:"
puts "  GET    /todos"
puts "  GET    /todos/:id"
puts "  POST   /todos"
puts "  PUT    /todos/:id"
puts "  DELETE /todos/:id"

server.listen
