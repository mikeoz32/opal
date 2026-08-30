require "../spec_helper"
require "../../../src/opal/data/dialects/sqlite"

private def schema_diff_model(& : LF::Data::Schema::ModelBuilder ->) : LF::Data::Schema::Model
  LF::Data::Schema::Model.build { |schema| yield schema }
end

private def schema_diff_snapshot(
  model : LF::Data::Schema::Model,
) : LF::Data::Schema::Snapshot
  LF::Data::Schema::Snapshot.from_model(model)
end

private def sqlite_schema_diff(
  desired : LF::Data::Schema::Model,
  actual : LF::Data::Schema::Snapshot,
  options : LF::Data::Schema::DiffOptions = LF::Data::Schema::DiffOptions.new,
) : LF::Data::Schema::DiffPlan
  LF::Data::Schema::Differ.new(LF::Data::Dialects::SQLite.new)
    .diff(desired, actual, options)
end

describe LF::Data::Schema::Differ do
  it "returns an empty deterministic plan for identical schemas" do
    desired = schema_diff_model do |schema|
      schema.table("projects") do |table|
        table.generated_id("id")
        table.string("name", null: false)
      end
    end

    plan = sqlite_schema_diff(desired, schema_diff_snapshot(desired))

    plan.empty?.should be_true
    plan.executable?.should be_true
    plan.operations.should be_empty
  end

  it "orders new referenced tables before dependants" do
    desired = schema_diff_model do |schema|
      schema.table("tasks") do |table|
        table.generated_id("id")
        table.int64("project_id", null: false)
        table.foreign_key(
          "project_id",
          references_table: "projects",
          references_column: "id"
        )
      end
      schema.table("projects") { |table| table.generated_id("id") }
    end

    plan = sqlite_schema_diff(desired, LF::Data::Schema::Snapshot.empty)

    plan.operations.map { |operation| operation.as(LF::Data::Schema::CreateTable).table.name }
      .should eq(["projects", "tasks"])
  end

  it "plans additive columns and indexes in stable name order" do
    actual_model = schema_diff_model do |schema|
      schema.table("projects") { |table| table.generated_id("id") }
    end
    desired = schema_diff_model do |schema|
      schema.table("projects") do |table|
        table.generated_id("id")
        table.string("slug")
        table.string("title", null: false, default: "untitled")
        table.index("idx_projects_title", "title")
        table.index("idx_projects_slug", "slug", unique: true)
      end
    end

    plan = sqlite_schema_diff(desired, schema_diff_snapshot(actual_model))

    plan.operations.map do |operation|
      case operation
      when LF::Data::Schema::AddColumn
        "column:#{operation.column.name}"
      when LF::Data::Schema::CreateIndex
        "index:#{operation.index.name}"
      else
        operation.class.to_s
      end
    end.should eq([
      "column:slug",
      "column:title",
      "index:idx_projects_slug",
      "index:idx_projects_title",
    ])
  end

  it "requires explicit rename hints and emits typed rename operations" do
    actual = schema_diff_model do |schema|
      schema.table("legacy_projects") do |table|
        table.generated_id("id")
        table.string("label")
      end
    end
    desired = schema_diff_model do |schema|
      schema.table("projects") do |table|
        table.generated_id("id")
        table.string("name")
      end
    end
    options = LF::Data::Schema::DiffOptions.new
      .rename_table("legacy_projects", "projects")
      .rename_column("projects", "label", "name")

    plan = sqlite_schema_diff(desired, schema_diff_snapshot(actual), options)

    plan.operations.should eq([
      LF::Data::Schema::RenameTable.new("legacy_projects", "projects"),
      LF::Data::Schema::RenameColumn.new("projects", "label", "name"),
    ])
  end

  it "keeps destructive changes visible and requires explicit opt in" do
    actual = schema_diff_model do |schema|
      schema.table("obsolete") { |table| table.generated_id("id") }
      schema.table("projects") do |table|
        table.generated_id("id")
        table.string("name")
        table.index("idx_projects_name", "name")
      end
    end
    desired = schema_diff_model do |schema|
      schema.table("projects") do |table|
        table.generated_id("id")
        table.string("name")
      end
    end

    plan = sqlite_schema_diff(desired, schema_diff_snapshot(actual))

    plan.destructive?.should be_true
    plan.steps.select(&.destructive?).map(&.description).should eq([
      "drop index idx_projects_name",
      "drop table obsolete",
    ])
    expect_raises(LF::Data::UnsafeSchemaChangeError) { plan.operations }
    plan.operations(allow_destructive: true).should eq([
      LF::Data::Schema::DropIndex.new("idx_projects_name"),
      LF::Data::Schema::DropTable.new("obsolete"),
    ])
  end

  it "reports removed columns and changed definitions instead of guessing" do
    actual = schema_diff_model do |schema|
      schema.table("projects") do |table|
        table.generated_id("id")
        table.string("legacy")
        table.string("name")
      end
    end
    desired = schema_diff_model do |schema|
      schema.table("projects") do |table|
        table.generated_id("id")
        table.text("name", null: false)
      end
    end

    plan = sqlite_schema_diff(desired, schema_diff_snapshot(actual))

    plan.executable?.should be_false
    plan.diagnostics.map(&.code).should eq([
      :column_definition_changed,
      :column_removed,
    ])
    expect_raises(LF::Data::UnresolvedSchemaDiffError) do
      plan.operations(allow_destructive: true)
    end
  end

  it "reports invalid rename hints without partially transforming the snapshot" do
    actual = schema_diff_model do |schema|
      schema.table("legacy") { |table| table.generated_id("id") }
      schema.table("projects") { |table| table.generated_id("id") }
    end
    desired = schema_diff_model do |schema|
      schema.table("projects") { |table| table.generated_id("id") }
    end
    options = LF::Data::Schema::DiffOptions.new
      .rename_table("legacy", "projects")

    plan = sqlite_schema_diff(desired, schema_diff_snapshot(actual), options)

    plan.executable?.should be_false
    plan.diagnostics.map(&.code).should eq([:invalid_table_rename])
  end

  it "rejects destructive table cycles instead of emitting an unusable order" do
    actual = schema_diff_model do |schema|
      schema.table("alpha") do |table|
        table.int64("beta_id")
        table.foreign_key(
          "beta_id",
          references_table: "beta",
          references_column: "id"
        )
      end
      schema.table("beta") do |table|
        table.int64("id")
        table.int64("alpha_id")
        table.foreign_key(
          "alpha_id",
          references_table: "alpha",
          references_column: "beta_id"
        )
      end
    end

    plan = sqlite_schema_diff(
      schema_diff_model { |_schema| },
      schema_diff_snapshot(actual)
    )

    plan.executable?.should be_false
    plan.diagnostics.map(&.code).should eq([:cyclic_table_drop_dependencies])
  end
end
