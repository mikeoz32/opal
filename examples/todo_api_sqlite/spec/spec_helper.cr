require "spec"
require "sqlite3"
require "../src/todo_api_sqlite"

module TodoExampleSpecSupport
  extend self

  def with_source(& : LF::Data::DataSource ->)
    source = LF::Data::DataSource.open(
      "sqlite3://%3Amemory%3A",
      dialect: LF::Data::Dialects::SQLite.new
    )
    LF::Data::MigrationRunner.new(source).run(TodoMigrations.build)
    yield source
  ensure
    source.try &.close
  end

  def service(source : LF::Data::DataSource) : TodoService
    TodoService.new(source, TodoRepository.new, TodoAuditRepository.new)
  end

  def cleanup_database(path : String) : Nil
    {path, "#{path}-wal", "#{path}-shm"}.each do |candidate|
      File.delete(candidate) if File.exists?(candidate)
    end
  end
end
