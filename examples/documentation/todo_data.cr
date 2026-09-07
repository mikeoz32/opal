# --8<-- [start:imports]
require "opal"
require "opal/data"
require "opal/data/dialects/sqlite"
require "sqlite3"
# --8<-- [end:imports]

# --8<-- [start:entity]
@[LF::Data::Table("todos")]
class Todo
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  @[LF::Data::Column]
  property title : String

  @[LF::Data::Version]
  getter version : Int64 = 0_i64

  def initialize(@title : String)
    @id = nil
  end
end

# --8<-- [end:entity]

# --8<-- [start:migration]
class CreateTodos < LF::Data::Migration
  def version : Int64
    1_i64
  end

  def name : String
    "create_todos"
  end

  def up(schema : LF::Data::SchemaEditor) : Nil
    schema.create_table("todos") do |table|
      table.generated_id("id")
      table.string("title", null: false)
      table.int64("version", null: false, default: 0_i64)
    end
  end
end

source = LF::Data::DataSource.open(
  "sqlite3://./todos.db",
  dialect: LF::Data::Dialects::SQLite.new,
)

begin
  migrations = LF::Data::MigrationSet.new(CreateTodos.new)
  LF::Data::MigrationRunner.new(source).run(migrations)
ensure
  source.close
end

# --8<-- [end:migration]

# --8<-- [start:create]
def create(source : LF::Data::DataSource, title : String) : Todo
  source.transaction do |manager|
    todo = Todo.new(title)
    manager.persist(todo)
    manager.flush
    todo
  end
end

# --8<-- [end:create]

# --8<-- [start:query]
def release_todos(source : LF::Data::DataSource) : Array(Todo)
  source.transaction do |manager|
    todos = manager.repository(Todo)
    todos.query
      .where(Todo::Fields.title.like("%release%"))
      .to_a
  end
end
# --8<-- [end:query]
