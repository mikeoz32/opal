require "../../spec_helper"
require "../../../../src/opal/data/dialects/sqlite"
require "../../support/sqlite_database"

private class SchemaInspectionListener
  include LF::Data::Listener

  getter events = [] of LF::Data::StatementCompletionEvent

  def on_statement_completion(event : LF::Data::StatementCompletionEvent) : Nil
    events << event
  end
end

private class SQLiteGeneratedCompatibilityMigration < LF::Data::Migration
  def version : Int64
    10_i64
  end

  def name : String
    "create_projects"
  end

  def up(schema : LF::Data::SchemaEditor) : Nil
    schema.create_table("projects") do |table|
      table.generated_id("id")
      table.string("name", null: false)
      table.bool("active", null: false, default: true)
      table.index("idx_projects_active", "active")
    end
  end
end

private class UnsupportedInspectionSQLite < LF::Data::Dialects::SQLite
  def supports?(capability : LF::Data::DialectCapability) : Bool
    return false if capability.schema_inspection?

    super
  end
end

describe LF::Data::Dialects::SQLite::SchemaIntrospector do
  it "normalizes portable tables, columns, constraints, defaults, and indexes" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.using_connection do |connection|
        schema = LF::Data::SchemaEditor.new(
          LF::Data::Dialects::SQLite.new.schema_renderer(connection)
        )
        schema.create_table("projects") do |table|
          table.generated_id("id")
          table.string("code", null: false, default: "can't")
          table.text("notes")
          table.bool("active", null: false, default: true)
          table.int32("priority", default: 2_i32)
          table.int64("version", null: false, default: 0_i64)
          table.float64("score", default: 1.5_f64)
          table.timestamp(
            "created_at",
            default: Time.utc(2026, 8, 30, 12, 30, 0)
          )
          table.bytes("payload", default: Bytes[0x0a, 0xff])
          table.unique("code", name: "uq_projects_code")
          table.index("idx_projects_active", "active")
        end
        schema.create_table("tasks") do |table|
          table.int64("project_id", null: false)
          table.int64("id", null: false)
          table.primary_key("project_id", "id", name: "pk_tasks")
          table.foreign_key(
            "project_id",
            references_table: "projects",
            references_column: "id",
            name: "fk_tasks_project"
          )
        end
      end

      listener = SchemaInspectionListener.new
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new,
        listeners: [listener]
      )
      snapshot = source.inspect_schema

      snapshot.tables.map(&.name).should eq(["projects", "tasks"])
      projects = snapshot.table("projects").not_nil!
      projects.columns.map(&.name).should eq([
        "id",
        "code",
        "notes",
        "active",
        "priority",
        "version",
        "score",
        "created_at",
        "payload",
      ])
      projects.column("id").not_nil!.generated?.should be_true
      projects.column("id").not_nil!.nullable?.should be_false
      projects.column("code").not_nil!.default.not_nil!.value.should eq("can't")
      projects.column("active").not_nil!.default.not_nil!.value.should eq(1_i64)
      projects.column("priority").not_nil!.default.not_nil!.value.should eq(2_i64)
      projects.column("score").not_nil!.default.not_nil!.value.should eq(1.5_f64)
      projects.column("created_at").not_nil!.default.not_nil!.value
        .should eq("2026-08-30T12:30:00Z")
      projects.column("payload").not_nil!.default.not_nil!.value
        .should eq(Bytes[0x0a, 0xff])
      projects.primary_key.not_nil!.columns.should eq(["id"])
      projects.unique_constraints.map(&.columns).should eq([["code"]])
      projects.indexes.should eq([
        LF::Data::Schema::IndexDefinition.new(
          "idx_projects_active",
          ["active"],
          false
        ),
      ])
      tasks = snapshot.table("tasks").not_nil!
      tasks.primary_key.not_nil!.columns.should eq(["project_id", "id"])
      tasks.foreign_keys.first.local_columns.should eq(["project_id"])
      tasks.foreign_keys.first.referenced_table.should eq("projects")
      tasks.foreign_keys.first.referenced_columns.should eq(["id"])

      listener.events.should_not be_empty
      listener.events.each do |event|
        event.operation.should eq(LF::Data::StatementOperation::Schema)
        event.error.should be_nil
      end
    end
  end

  it "drives an additive diff and generated migration through MigrationRunner" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )
      model = LF::Data::Schema::Model.build do |schema|
        schema.table("projects") do |table|
          table.generated_id("id")
          table.string("name", null: false)
          table.bool("active", null: false, default: true)
          table.index("idx_projects_active", "active")
        end
      end

      generator = LF::Data::Schema::MigrationGenerator.new(source)
      plan = generator.plan(model)
      plan.operations.size.should eq(1)
      plan.operations.first.should be_a(LF::Data::Schema::CreateTable)

      migration_source = generator.generate(
        model,
        version: 10_i64,
        name: "create_projects",
        class_name: "CreateProjects"
      )
      migration_source.should contain("class CreateProjects")

      LF::Data::MigrationRunner.new(source).run(
        LF::Data::MigrationSet.new(SQLiteGeneratedCompatibilityMigration.new)
      )

      generator.plan(model).empty?.should be_true
    end
  end

  it "skips explicitly unmanaged tables before inspecting non-portable artifacts" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.exec("CREATE TABLE unmanaged (payload JSON)")
      database.exec(
        "CREATE INDEX idx_unmanaged_partial ON unmanaged (payload) " \
        "WHERE payload IS NOT NULL"
      )
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )
      options = LF::Data::Schema::DiffOptions.new.ignore_table("unmanaged")
      model = LF::Data::Schema::Model.build { |_schema| }

      LF::Data::Schema::MigrationGenerator.new(source)
        .plan(model, options)
        .empty?.should be_true
    end
  end

  it "fails with a typed error before datasource work when inspection is unsupported" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      source = LF::Data::DataSource.new(
        database,
        dialect: UnsupportedInspectionSQLite.new
      )

      error = expect_raises(LF::Data::UnsupportedSchemaInspectionError) do
        source.inspect_schema
      end

      error.dialect.should eq("sqlite")
    end
  end
end
