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
        manager.persist(project)
        manager.flush

        first = Task.new(project.id.not_nil!, "write data docs")
        second = Task.new(project.id.not_nil!, "try dynamic queries")
        manager.persist(first)
        manager.persist(second)
        manager.flush
        manager.persist(TaskEvent.new(second.id.not_nil!, "created"))
        {project, first, second}
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
        event_fields = TaskEvent::Fields
        manager.dynamic_query(TaskEvent)
          .where(event_fields.task_id.eq(task_id))
          .to_a.each do |event|
          manager.remove(event)
        end

        task = manager.find(Task, task_id).not_nil!
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
