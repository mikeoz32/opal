require "./spec_helper"

private def relationship_showcase_graph
  project = DataLayerExample::Project.new("relationships")
  profile = DataLayerExample::ProjectProfile.new(project, "primary")
  first = DataLayerExample::Task.new(project, "first")
  second = DataLayerExample::Task.new(project, "second")
  event = DataLayerExample::TaskEvent.new(second, "created")
  project.profile = profile
  project.tasks << first << second
  second.events << event
  {project, profile, first, second, event}
end

describe "the data layer showcase" do
  it "runs ordered migrations and enables SQLite foreign keys" do
    DataLayerExampleSpecSupport.with_store(allow_sqlite_cleanup_error: true) do |store|
      store.source.transaction do |manager|
        manager.connection.scalar("PRAGMA foreign_keys").should eq(1_i64)
        manager.connection.scalar(
          "SELECT count(*) FROM _lf_migrations"
        ).should eq(4_i64)
      end

      error = expect_raises(SQLite3::Exception) do
        store.source.transaction do |manager|
          manager.persist(DataLayerExample::Task.new(999_i64, "orphan"))
          manager.flush
        end
      end
      error.message.not_nil!.should contain("FOREIGN KEY")
    end
  end

  it "maps generated IDs, converters, nullable fields, and ignored fields" do
    DataLayerExampleSpecSupport.with_store do |store|
      created_task = store.source.transaction do |manager|
        project = DataLayerExample::Project.new("opal")
        manager.persist(project)
        manager.flush

        created = DataLayerExample::Task.new(
          project.id.not_nil!,
          "write example",
          due_at: nil,
          created_at: Time.utc(2026, 8, 25)
        )
        manager.persist(created)
        manager.flush
        created
      end

      created_task.id.should_not be_nil
      created_task.version.should eq(0_i64)

      store.source.transaction do |manager|
        loaded = manager.find(DataLayerExample::Task, created_task.id.not_nil!).not_nil!
        loaded.created_at.should eq(Time.utc(2026, 8, 25))
        loaded.due_at.should be_nil
        loaded.display_label.should eq("hydrated")
      end
    end
  end

  it "persists a relationship graph and propagates generated foreign keys" do
    DataLayerExampleSpecSupport.with_store do |store|
      project, profile, first, second, event = relationship_showcase_graph

      store.source.transaction do |manager|
        manager.persist(project)
        manager.flush
      end

      project.id.should_not be_nil
      profile.project_id.should eq(project.id)
      first.project_id.should eq(project.id)
      second.project_id.should eq(project.id)
      event.task_id.should eq(second.id)

      store.source.transaction do |manager|
        manager.query(DataLayerExample::Project).count.should eq(1_i64)
        manager.query(DataLayerExample::ProjectProfile).count.should eq(1_i64)
        manager.query(DataLayerExample::Task).count.should eq(2_i64)
        manager.query(DataLayerExample::TaskEvent).count.should eq(1_i64)
      end
    end
  end

  it "loads relationships explicitly before cascading owner-side removal" do
    DataLayerExampleSpecSupport.with_store do |store|
      project, _, _, _, _ = relationship_showcase_graph
      store.source.transaction { |manager| manager.persist(project) }

      store.source.transaction do |manager|
        loaded = manager.find(
          DataLayerExample::Project,
          project.id.not_nil!
        ).not_nil!

        loaded.tasks.should be_empty
        loaded.profile.should be_nil

        loaded.tasks.concat(
          manager.query(DataLayerExample::Task)
            .where(
              DataLayerExample::Task::Fields.project_id.eq(
                project.id.not_nil!
              )
            )
            .to_a
        )
        loaded.profile = manager.query(DataLayerExample::ProjectProfile)
          .where(
            DataLayerExample::ProjectProfile::Fields.project_id.eq(
              project.id.not_nil!
            )
          )
          .first?
        loaded.tasks.each do |task|
          task.events.concat(
            manager.query(DataLayerExample::TaskEvent)
              .where(DataLayerExample::TaskEvent::Fields.task_id.eq(task.id.not_nil!))
              .to_a
          )
        end

        manager.remove(loaded)
      end

      store.source.transaction do |manager|
        manager.query(DataLayerExample::TaskEvent).count.should eq(0_i64)
        manager.query(DataLayerExample::Task).count.should eq(0_i64)
        manager.query(DataLayerExample::ProjectProfile).count.should eq(0_i64)
        manager.query(DataLayerExample::Project).count.should eq(0_i64)
      end
    end
  end

  it "does not turn collection mutation into orphan removal" do
    DataLayerExampleSpecSupport.with_store do |store|
      project, _, _, _, _ = relationship_showcase_graph
      store.source.transaction { |manager| manager.persist(project) }

      store.source.transaction do |manager|
        loaded = manager.find(
          DataLayerExample::Project,
          project.id.not_nil!
        ).not_nil!
        loaded.tasks.concat(
          manager.query(DataLayerExample::Task)
            .where(
              DataLayerExample::Task::Fields.project_id.eq(
                project.id.not_nil!
              )
            )
            .to_a
        )
        loaded.tasks.pop
        manager.persist(loaded)
      end

      store.source.transaction do |manager|
        manager.query(DataLayerExample::Task).count.should eq(2_i64)
      end
    end
  end

  it "supports static and dynamic queries without implicit flush" do
    DataLayerExampleSpecSupport.with_store do |store|
      project_id = store.source.transaction do |manager|
        project = DataLayerExample::Project.new("opal")
        manager.persist(project)
        manager.flush
        project.id.not_nil!
      end

      store.source.transaction do |manager|
        manager.persist(DataLayerExample::Task.new(project_id, "write docs"))
        manager.persist(DataLayerExample::Task.new(project_id, "ship release"))

        fields = DataLayerExample::Task::Fields
        manager.query(DataLayerExample::Task)
          .where(fields.project_id.eq(project_id))
          .where(fields.due_at.is_nil)
          .to_a.should be_empty

        manager.dynamic_query(DataLayerExample::Task)
          .where(fields.title.like("%ship%"))
          .to_a.should be_empty

        manager.query(DataLayerExample::Task).limit(0).first?.should be_nil
      end

      store.source.transaction do |manager|
        fields = DataLayerExample::Task::Fields
        manager.query(DataLayerExample::Task)
          .where(fields.project_id.eq(project_id))
          .order_by(fields.title.asc)
          .to_a.map(&.title).should eq(["ship release", "write docs"])

        manager.dynamic_query(DataLayerExample::Task)
          .where(fields.title.like("%ship%"))
          .first?.not_nil!.title.should eq("ship release")
      end
    end
  end

  it "increments versions for bulk updates and detaches cached entities" do
    DataLayerExampleSpecSupport.with_store do |store|
      task_id = store.source.transaction do |manager|
        project = DataLayerExample::Project.new("opal")
        manager.persist(project)
        manager.flush
        task = DataLayerExample::Task.new(project.id.not_nil!, "pending")
        manager.persist(task)
        manager.flush
        task.id.not_nil!
      end

      store.source.transaction do |manager|
        fields = DataLayerExample::Task::Fields
        affected = manager.update(DataLayerExample::Task)
          .set(fields.completed, true)
          .where(fields.id.eq(task_id))
          .execute
        affected.should eq(1_i64)
      end

      store.source.transaction do |manager|
        task = manager.find(DataLayerExample::Task, task_id).not_nil!
        task.completed.should be_true
        task.version.should eq(1_i64)
      end
    end
  end

  it "keeps raw SQL explicit and lets clear reload the identity map" do
    DataLayerExampleSpecSupport.with_store do |store|
      task_id = store.source.transaction do |manager|
        project = DataLayerExample::Project.new("opal")
        manager.persist(project)
        manager.flush
        task = DataLayerExample::Task.new(project.id.not_nil!, "before raw SQL")
        manager.persist(task)
        manager.flush
        task.id.not_nil!
      end

      store.source.transaction do |manager|
        managed = manager.find(DataLayerExample::Task, task_id).not_nil!
        manager.connection.exec(
          "UPDATE showcase_tasks SET task_title = ? WHERE id = ?",
          "after raw SQL",
          task_id
        )
        manager.find(DataLayerExample::Task, task_id).not_nil!.title
          .should eq("before raw SQL")

        manager.clear(DataLayerExample::Task)
        manager.find(DataLayerExample::Task, task_id).not_nil!.title
          .should eq("after raw SQL")
        expect_raises(LF::Data::DetachedEntityError) do
          manager.persist(managed)
        end
      end
    end
  end

  it "rolls back earlier writes when a later operation fails" do
    DataLayerExampleSpecSupport.with_store(allow_sqlite_cleanup_error: true) do |store|
      expect_raises(SQLite3::Exception) do
        store.source.transaction do |manager|
          first = DataLayerExample::Project.new("rollback")
          manager.persist(first)
          manager.flush
          duplicate = DataLayerExample::Project.new("rollback")
          manager.persist(duplicate)
          manager.flush
        end
      end

      store.source.transaction do |manager|
        manager.connection.scalar(
          "SELECT count(*) FROM showcase_projects WHERE name = 'rollback'"
        ).should eq(0_i64)
      end
    end
  end

  it "reports stale writes through optimistic locking across data sources" do
    path = File.tempname("opal-data-example")
    url = "sqlite3:#{path}"
    store = nil.as(DataLayerExample::Store?)
    first_database = nil.as(DB::Database?)
    second_database = nil.as(DB::Database?)
    store = DataLayerExample::Store.open(url)
    store.migrate
    task_id = store.source.transaction do |manager|
      project = DataLayerExample::Project.new("opal")
      manager.persist(project)
      manager.flush
      task = DataLayerExample::Task.new(project.id.not_nil!, "initial")
      manager.persist(task)
      manager.flush
      task.id.not_nil!
    end
    store.close
    store = nil

    first_database = DB.open(url)
    second_database = DB.open(url)
    dialect = LF::Data::Dialects::SQLite.new
    dispatcher = LF::Data::Internal::ListenerDispatcher.new

    first_database.using_connection do |first_connection|
      second_database.using_connection do |second_connection|
        first_manager = LF::Data::EntityManager.new(
          first_connection,
          dialect,
          dispatcher
        )
        second_manager = LF::Data::EntityManager.new(
          second_connection,
          dialect,
          dispatcher
        )

        begin
          stale = first_manager.find(DataLayerExample::Task, task_id).not_nil!
          current = second_manager.find(DataLayerExample::Task, task_id).not_nil!

          current.title = "winner"
          second_manager.persist(current)
          second_manager.flush

          stale.title = "stale"
          first_manager.persist(stale)
          error = expect_raises(LF::Data::OptimisticLockError) do
            first_manager.flush
          end
          error.operation.should eq(:update)
        ensure
          first_manager.close
          second_manager.close
        end
      end
    end
  ensure
    first_database.try &.close
    second_database.try &.close
    store.try &.close
    File.delete(path) if path && File.exists?(path)
  end

  it "emits migration and transaction statements to a listener" do
    listener = DataLayerExample::TraceListener.new
    store = DataLayerExample::Store.open(
      "sqlite3://%3Amemory%3A",
      [listener] of LF::Data::Listener
    )
    store.migrate

    store.source.transaction do |manager|
      manager.persist(DataLayerExample::Project.new("opal"))
    end

    listener.transaction_outcomes.should_not be_empty
    listener.transaction_outcomes.all?(&.committed?).should be_true
    listener.statements.any? { |event| event.operation.schema? }.should be_true
    listener.statements.any? { |event| event.operation.insert? }.should be_true
  ensure
    store.try &.close
  end
end
