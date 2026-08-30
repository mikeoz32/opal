require "../spec_helper"
require "../../../src/opal/data"

describe LF::Data::Schema::Model do
  it "builds an explicit, deterministically ordered schema authority" do
    model = LF::Data::Schema::Model.build do |schema|
      schema.table("tasks") do |table|
        table.generated_id("id")
        table.int64("project_id", null: false)
        table.foreign_key(
          "project_id",
          references_table: "projects",
          references_column: "id",
          name: "fk_tasks_project"
        )
      end
      schema.table("projects") do |table|
        table.generated_id("id")
        table.string("name", null: false)
      end
    end

    model.tables.map(&.name).should eq(["projects", "tasks"])
    model.table("tasks").not_nil!.foreign_keys.first.referenced_table
      .should eq("projects")
  end

  it "rejects duplicate tables, the migration history table, and broken references" do
    expect_raises(ArgumentError, /Duplicate schema table/) do
      LF::Data::Schema::Model.build do |schema|
        2.times { schema.table("projects") { |table| table.generated_id("id") } }
      end
    end

    expect_raises(ArgumentError, /reserved/) do
      LF::Data::Schema::Model.build do |schema|
        schema.table("_lf_migrations") { |table| table.generated_id("id") }
      end
    end

    expect_raises(ArgumentError, /missing table/) do
      LF::Data::Schema::Model.build do |schema|
        schema.table("tasks") do |table|
          table.int64("project_id")
          table.foreign_key(
            "project_id",
            references_table: "projects",
            references_column: "id"
          )
        end
      end
    end
  end

  it "rejects index names that collide across tables" do
    expect_raises(ArgumentError, /Duplicate schema index/) do
      LF::Data::Schema::Model.build do |schema|
        schema.table("projects") do |table|
          table.int64("id")
          table.index("idx_identity", "id")
        end
        schema.table("tasks") do |table|
          table.int64("id")
          table.index("idx_identity", "id")
        end
      end
    end
  end
end
