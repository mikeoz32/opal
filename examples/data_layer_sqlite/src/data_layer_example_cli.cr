require "sqlite3"
require "./data_layer_example"

module DataLayerExample
  module CLI
    extend self

    def run : Nil
      url = ENV.fetch("OPAL_DATA_EXAMPLE_URL", "sqlite3://%3Amemory%3A")
      listener = TraceListener.new
      store = Store.open(url, [listener] of LF::Data::Listener)

      begin
        store.migrate
        project, first_task, second_task = seed(store)
        demonstrate_explicit_relationship_loading(store, project.id.not_nil!)
        demonstrate_queries(store, project.id.not_nil!)
        demonstrate_bulk_update(store, project.id.not_nil!)
        demonstrate_unit_of_work(store, first_task.id.not_nil!)
        demonstrate_delete(store, second_task.id.not_nil!)

        puts "data layer showcase: ok"
        puts "project_id=#{project.id}"
        puts "remaining_tasks=#{count_tasks(store)}"
        puts "transactions=#{listener.transaction_outcomes.size}"
        puts "statements=#{listener.statements.size}"
      ensure
        store.close
      end
    end

    private def seed(store : Store) : {Project, Task, Task}
      store.source.transaction do |manager|
        project = Project.new("opal")
        project.profile = ProjectProfile.new(project, "primary")
        first = Task.new(project, "write data docs")
        second = Task.new(project, "try dynamic queries")
        second.events << TaskEvent.new(second, "created")
        project.tasks << first << second

        manager.persist(project)
        manager.flush
        {project, first, second}
      end
    end

    private def demonstrate_explicit_relationship_loading(
      store : Store,
      project_id : Int64,
    ) : Nil
      store.source.transaction do |manager|
        project = manager.find(Project, project_id).not_nil!
        puts "implicit_tasks=#{project.tasks.size}"
        puts "implicit_profile=#{project.profile.nil?}"

        project.tasks.concat(
          manager.query(Task)
            .where(Task::Fields.project_id.eq(project_id))
            .order_by(Task::Fields.id.asc)
            .to_a
        )
        project.profile = manager.query(ProjectProfile)
          .where(ProjectProfile::Fields.project_id.eq(project_id))
          .first?
        puts "explicit_tasks=#{project.tasks.size}"
        puts "explicit_profile=#{project.profile.try(&.label) || "none"}"
      end
    end

    private def demonstrate_queries(store : Store, project_id : Int64) : Nil
      store.source.transaction do |manager|
        fields = Task::Fields
        static = manager.query(Task)
          .where(fields.project_id.eq(project_id))
          .where(fields.completed.eq(false))
          .order_by(fields.title.asc)
          .to_a
        dynamic = manager.dynamic_query(Task)
          .where(fields.title.like("%dynamic%"))
          .first?

        puts "static_pending=#{static.size}"
        puts "dynamic_match=#{dynamic.try(&.title) || "none"}"
      end
    end

    private def demonstrate_bulk_update(store : Store, project_id : Int64) : Nil
      store.source.transaction do |manager|
        fields = Task::Fields
        affected = manager.update(Task)
          .set(fields.completed, true)
          .where(fields.project_id.eq(project_id))
          .execute
        puts "bulk_completed=#{affected}"
      end
    end

    private def demonstrate_unit_of_work(store : Store, task_id : Int64) : Nil
      store.source.transaction do |manager|
        task = manager.find(Task, task_id).not_nil!
        task.title = "write more data docs"
        manager.persist(task)
      end
    end

    private def demonstrate_delete(store : Store, task_id : Int64) : Nil
      store.source.transaction do |manager|
        task = manager.find(Task, task_id).not_nil!
        task.events.concat(
          manager.dynamic_query(TaskEvent)
            .where(TaskEvent::Fields.task_id.eq(task_id))
            .to_a
        )
        manager.remove(task)
      end
    end

    private def count_tasks(store : Store) : Int64
      store.source.transaction do |manager|
        manager.query(Task).count
      end
    end
  end
end

DataLayerExample::CLI.run
