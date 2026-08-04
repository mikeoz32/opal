require "../spec_helper"
require "../../../src/opal/data"
require "../support/sqlite_database"

private class SchemaRendererProbe < LF::Data::SchemaRenderer
  getter operations = [] of LF::Data::Schema::Operation

  def execute(
    operation : LF::Data::Schema::Operation,
    observer : LF::Data::StatementObserver? = nil,
  ) : Nil
    @operations << operation
  end
end

private class UnsupportedSchemaDialect < LF::Data::Dialect
  def name : String
    "unsupported-schema"
  end

  def quote_identifier(identifier : String) : String
    identifier
  end

  def placeholder(position : Int32) : String
    "?"
  end

  def find_plan(entity : T.class) : LF::Data::SQL::StatementPlan forall T
    LF::Data::SQL::StatementPlan.new("find")
  end

  def insert_plan(entity : T.class) : LF::Data::SQL::InsertPlan forall T
    LF::Data::SQL::InsertPlan.new(
      "insert",
      LF::Data::SQL::GeneratedKeySource::None,
      nil
    )
  end

  def update_plan(entity : T.class) : LF::Data::SQL::StatementPlan forall T
    LF::Data::SQL::StatementPlan.new("update")
  end

  def delete_plan(entity : T.class) : LF::Data::SQL::StatementPlan forall T
    LF::Data::SQL::StatementPlan.new("delete")
  end

  def select_plan(entity : T.class, shape : S.class) : LF::Data::SQL::StatementPlan forall T, S
    LF::Data::SQL::StatementPlan.new("select")
  end

  def update_query_plan(entity : T.class, shape : S.class) : LF::Data::SQL::StatementPlan forall T, S
    LF::Data::SQL::StatementPlan.new("bulk update")
  end

  def delete_query_plan(entity : T.class, shape : S.class) : LF::Data::SQL::StatementPlan forall T, S
    LF::Data::SQL::StatementPlan.new("bulk delete")
  end

  def supports?(capability : LF::Data::DialectCapability) : Bool
    false
  end
end

describe LF::Data::SchemaEditor do
  it "delegates validated typed operations in declared order" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.using_connection do |connection|
        renderer = SchemaRendererProbe.new(connection)
        schema = LF::Data::SchemaEditor.new(renderer)

        schema.create_table("todos") do |table|
          table.generated_id("id")
          table.string("title", null: false)
          table.index("idx_todos_title", "title")
        end
        schema.add_column("todos") do |table|
          table.bool("completed", null: false, default: false)
        end
        schema.rename_column("todos", "title", "summary")
        schema.create_index("todos", "idx_todos_completed", "completed")
        schema.drop_index("idx_todos_completed")
        schema.drop_table("todos")
        schema.raw("cleanup", "DELETE FROM orphaned_rows")

        renderer.operations.map(&.class).should eq([
          LF::Data::Schema::CreateTable,
          LF::Data::Schema::AddColumn,
          LF::Data::Schema::RenameColumn,
          LF::Data::Schema::CreateIndex,
          LF::Data::Schema::DropIndex,
          LF::Data::Schema::DropTable,
          LF::Data::Schema::RawSQL,
        ])
        create = renderer.operations.first.as(LF::Data::Schema::CreateTable)
        create.table.indexes.first.name.should eq("idx_todos_title")
        add = renderer.operations[1].as(LF::Data::Schema::AddColumn)
        add.column.name.should eq("completed")
        renderer.operations.last.as(LF::Data::Schema::RawSQL).name.should eq("cleanup")
      end
    end
  end

  it "requires add_column to define exactly one plain column" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.using_connection do |connection|
        schema = LF::Data::SchemaEditor.new(SchemaRendererProbe.new(connection))

        expect_raises(ArgumentError, /exactly one/) do
          schema.add_column("todos") { |_table| }
        end
        expect_raises(ArgumentError, /exactly one/) do
          schema.add_column("todos") do |table|
            table.string("first")
            table.string("second")
          end
        end
        expect_raises(ArgumentError, /plain column/) do
          schema.add_column("todos") { |table| table.generated_id("id") }
        end
      end
    end
  end

  it "validates editor identifiers and raw operation names before delegation" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.using_connection do |connection|
        renderer = SchemaRendererProbe.new(connection)
        schema = LF::Data::SchemaEditor.new(renderer)

        expect_raises(ArgumentError, /identifier/) { schema.drop_table("") }
        expect_raises(ArgumentError, /identifier/) do
          schema.raw("", "SELECT 1")
        end
        renderer.operations.should be_empty
      end
    end
  end

  it "keeps SchemaEditor independent from concrete dialects" do
    source = File.read(File.expand_path("../../../src/opal/data/schema_editor.cr", __DIR__))

    source.should_not contain("case dialect")
    source.should_not contain("Dialects::")
  end
end

describe LF::Data::SchemaRenderer do
  it "keeps the transaction connection read-only" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.using_connection do |connection|
        renderer = SchemaRendererProbe.new(connection)

        renderer.connection.should be(connection)
        renderer.responds_to?(:connection=).should be_false
      end
    end
  end

  it "uses a typed default error for dialects without schema support" do
    dialect = UnsupportedSchemaDialect.new

    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.using_connection do |connection|
        error = expect_raises(LF::Data::UnsupportedSchemaOperationError) do
          dialect.schema_renderer(connection)
        end

        error.dialect.should eq("unsupported-schema")
        error.operation.should eq("schema migrations")
      end
    end
  end
end
