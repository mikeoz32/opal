require "./migrations/create_todos"

module TodoMigrations
  extend self

  def build : LF::Data::MigrationSet
    LF::Data::MigrationSet.new(CreateTodos.new)
  end
end
