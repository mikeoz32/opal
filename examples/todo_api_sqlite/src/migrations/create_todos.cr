class CreateTodos < LF::Data::Migration
  def version : Int64
    1_i64
  end

  def name : String
    "create_todos_and_audits"
  end

  def up(schema : LF::Data::SchemaEditor) : Nil
    schema.create_table("todos") do |table|
      table.generated_id("id")
      table.string("title", null: false)
      table.bool("completed", null: false, default: false)
      table.timestamp("created_at", null: false)
      table.int64("version", null: false, default: 0_i64)
    end

    schema.create_table("todo_audits") do |table|
      table.generated_id("id")
      table.int64("todo_id", null: false)
      table.string("action", null: false)
      table.timestamp("created_at", null: false)
      table.index("idx_todo_audits_todo", "todo_id")
    end
  end
end
