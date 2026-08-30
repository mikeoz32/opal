require "./spec_helper"

describe TodoRepository do
  it "runs the versioned schema migration once" do
    TodoExampleSpecSupport.with_source do |source|
      LF::Data::MigrationRunner.new(source).run(TodoMigrations.build)

      source.transaction do |manager|
        manager.connection.scalar(
          "SELECT count(*) FROM _lf_migrations"
        ).should eq(1_i64)
        manager.connection.scalar(
          "SELECT count(*) FROM sqlite_master " \
          "WHERE type = 'table' AND name IN ('todos', 'todo_audits')"
        ).should eq(2_i64)
      end
    end
  end

  it "creates, finds, lists, updates, and deletes mapped todos" do
    TodoExampleSpecSupport.with_source do |source|
      repository = TodoRepository.new
      created_at = Time.utc(2026, 8, 30, 10, 15, 0)
      created = source.transaction do |manager|
        todo = Todo.new("write docs", created_at: created_at)
        manager.persist(todo)
        manager.flush
        todo
      end

      created.id.should_not be_nil
      created.version.should eq(0_i64)

      source.transaction do |manager|
        repository.all(manager).map(&.title).should eq(["write docs"])
        loaded = repository.find(manager, created.id.not_nil!).not_nil!
        loaded.created_at.should eq(created_at)
      end

      updated = source.transaction do |manager|
        repository.update(
          manager,
          created.id.not_nil!,
          "publish docs",
          nil
        ).not_nil!
      end
      updated.title.should eq("publish docs")
      updated.completed.should be_false
      updated.version.should eq(1_i64)

      completed = source.transaction do |manager|
        repository.update(
          manager,
          created.id.not_nil!,
          nil,
          true
        ).not_nil!
      end
      completed.completed.should be_true
      completed.version.should eq(2_i64)

      source.transaction do |manager|
        repository.delete(manager, created.id.not_nil!).should be_true
      end
      source.transaction do |manager|
        repository.find(manager, created.id.not_nil!).should be_nil
        repository.delete(manager, created.id.not_nil!).should be_false
      end
    end
  end
end
