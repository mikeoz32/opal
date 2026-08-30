require "spec"
require "pg"
require "../src/opal/data"
require "../src/opal/data/dialects/postgresql"

POSTGRESQL_SCHEMA_URL = ENV["OPAL_POSTGRESQL_URL"]? || raise(
  "OPAL_POSTGRESQL_URL is required for PostgreSQL schema generation specs"
)

private def postgresql_schema_model : LF::Data::Schema::Model
  LF::Data::Schema::Model.build do |schema|
    schema.table("opal_pg_schema_projects") do |table|
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
      table.unique("code", name: "uq_opal_pg_schema_projects_code")
      table.index("idx_opal_pg_schema_projects_active", "active")
    end
    schema.table("opal_pg_schema_tasks") do |table|
      table.int64("project_id", null: false)
      table.int64("id", null: false)
      table.primary_key(
        "project_id",
        "id",
        name: "pk_opal_pg_schema_tasks"
      )
      table.foreign_key(
        "project_id",
        references_table: "opal_pg_schema_projects",
        references_column: "id",
        name: "fk_opal_pg_schema_tasks_project"
      )
    end
  end
end

private class CreatePostgreSQLSchemaModel < LF::Data::Migration
  def version : Int64
    100_i64
  end

  def name : String
    "create_postgresql_schema_model"
  end

  def up(schema : LF::Data::SchemaEditor) : Nil
    schema.create_table("opal_pg_schema_projects") do |table|
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
      table.unique("code", name: "uq_opal_pg_schema_projects_code")
      table.index("idx_opal_pg_schema_projects_active", "active")
    end
    schema.create_table("opal_pg_schema_tasks") do |table|
      table.int64("project_id", null: false)
      table.int64("id", null: false)
      table.primary_key(
        "project_id",
        "id",
        name: "pk_opal_pg_schema_tasks"
      )
      table.foreign_key(
        "project_id",
        references_table: "opal_pg_schema_projects",
        references_column: "id",
        name: "fk_opal_pg_schema_tasks_project"
      )
    end
  end
end

private def reset_postgresql_schema_generation : Nil
  DB.open(POSTGRESQL_SCHEMA_URL) do |database|
    database.exec("DROP TABLE IF EXISTS opal_pg_schema_tasks CASCADE")
    database.exec("DROP TABLE IF EXISTS opal_pg_schema_projects CASCADE")
    database.exec("DROP TABLE IF EXISTS _lf_migrations CASCADE")
  end
end

describe "PostgreSQL schema inspection and migration generation" do
  before_each { reset_postgresql_schema_generation }
  after_each { reset_postgresql_schema_generation }

  it "plans, generates, applies, and then observes an empty diff" do
    source = nil.as(LF::Data::DataSource?)
    source = LF::Data::DataSource.open(
      POSTGRESQL_SCHEMA_URL,
      dialect: LF::Data::Dialects::PostgreSQL.new
    )
    model = postgresql_schema_model
    generator = LF::Data::Schema::MigrationGenerator.new(source)

    initial = generator.plan(model)
    initial.operations.map do |operation|
      operation.as(LF::Data::Schema::CreateTable).table.name
    end.should eq([
      "opal_pg_schema_projects",
      "opal_pg_schema_tasks",
    ])
    generator.generate(
      model,
      version: 100_i64,
      name: "create_postgresql_schema_model",
      class_name: "CreatePostgreSQLSchemaModel"
    ).should contain("class CreatePostgreSQLSchemaModel")

    LF::Data::MigrationRunner.new(
      source,
      lock_namespace: "opal-schema-generation",
      lock_timeout: 2.seconds
    ).run(
      LF::Data::MigrationSet.new(CreatePostgreSQLSchemaModel.new)
    )

    snapshot = source.inspect_schema
    projects = snapshot.table("opal_pg_schema_projects").not_nil!
    projects.column("id").not_nil!.generated?.should be_true
    projects.column("code").not_nil!.default.not_nil!.value.should eq("can't")
    projects.column("active").not_nil!.default.not_nil!.value.should be_true
    projects.column("priority").not_nil!.default.not_nil!.value.should eq(2_i64)
    projects.column("score").not_nil!.default.not_nil!.value.should eq(1.5_f64)
    projects.column("created_at").not_nil!.default.not_nil!.value
      .should eq(Time.utc(2026, 8, 30, 12, 30, 0))
    projects.column("payload").not_nil!.default.not_nil!.value
      .should eq(Bytes[0x0a, 0xff])
    projects.primary_key.not_nil!.columns.should eq(["id"])
    projects.unique_constraints.first.name
      .should eq("uq_opal_pg_schema_projects_code")
    projects.indexes.first.name.should eq("idx_opal_pg_schema_projects_active")
    tasks = snapshot.table("opal_pg_schema_tasks").not_nil!
    tasks.primary_key.not_nil!.columns.should eq(["project_id", "id"])
    tasks.foreign_keys.first.name
      .should eq("fk_opal_pg_schema_tasks_project")
    tasks.foreign_keys.first.referenced_table
      .should eq("opal_pg_schema_projects")

    generator.plan(model).empty?.should be_true
  ensure
    source.try &.close
  end
end
