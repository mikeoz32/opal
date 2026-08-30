require "./spec_helper"

describe TodoService do
  it "owns transaction boundaries and composes todo and audit repositories" do
    TodoExampleSpecSupport.with_source do |source|
      service = TodoExampleSpecSupport.service(source)

      service.all.should be_empty
      todo = service.create("ship Data v1")
      todo.id.should_not be_nil
      todo.version.should eq(0_i64)
      service.audits(todo.id.not_nil!).map(&.action).should eq(["created"])

      updated = service.update(
        todo.id.not_nil!,
        nil,
        true
      ).not_nil!
      updated.completed.should be_true
      updated.version.should eq(1_i64)
      service.audits(todo.id.not_nil!).map(&.action).should eq([
        "created",
        "updated",
      ])

      service.delete(todo.id.not_nil!).should be_true
      service.find(todo.id.not_nil!).should be_nil
      service.audits(todo.id.not_nil!).map(&.action).should eq([
        "created",
        "updated",
        "deleted",
      ])
      service.delete(todo.id.not_nil!).should be_false
    end
  end

  it "rolls back todo and audit writes atomically" do
    TodoExampleSpecSupport.with_source do |source|
      service = TodoExampleSpecSupport.service(source)

      expect_raises(TodoAuditFailure) do
        service.create_then_fail("must roll back")
      end

      service.all.should be_empty
      source.transaction do |manager|
        manager.query(TodoAudit).to_a.should be_empty
      end
    end
  end

  it "reports optimistic stale updates" do
    TodoExampleSpecSupport.with_source do |source|
      service = TodoExampleSpecSupport.service(source)
      todo_id = service.create("initial").id.not_nil!

      expect_raises(LF::Data::OptimisticLockError) do
        source.transaction do |manager|
          stale = manager.find(Todo, todo_id).not_nil!
          manager.connection.exec(
            "UPDATE todos SET title = ?, version = version + 1 WHERE id = ?",
            "winner",
            todo_id
          )

          stale.title = "stale"
          manager.persist(stale)
        end
      end

      service.find(todo_id).not_nil!.title.should eq("initial")
    end
  end
end
