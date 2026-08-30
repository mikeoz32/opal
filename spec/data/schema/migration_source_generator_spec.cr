require "../spec_helper"
require "../../../src/opal/data/dialects/sqlite"
require "../support/compile_fixture"

describe LF::Data::Schema::MigrationSourceGenerator do
  it "generates stable, readable Crystal source that implements Migration" do
    table = LF::Data::Schema::TableBuilder.new("projects")
    table.generated_id("id")
    table.string("name", null: false, default: "Opal's project")
    table.bool("active", null: false, default: true)
    table.timestamp(
      "created_at",
      default: Time::Format::RFC_3339.parse("2026-08-30T12:30:00.123456789Z")
    )
    table.bytes("payload", default: Bytes[0x0a, 0xff])
    table.bytes("empty_payload", default: Bytes.new(0))
    table.unique("name", name: "uq_projects_name")
    table.index("idx_projects_active", "active")
    steps = [
      LF::Data::Schema::DiffStep.safe(
        LF::Data::Schema::CreateTable.new(table.build),
        "create table projects"
      ),
      LF::Data::Schema::DiffStep.safe(
        LF::Data::Schema::RenameColumn.new("projects", "name", "title"),
        "rename projects.name to title"
      ),
    ]
    plan = LF::Data::Schema::DiffPlan.new("sqlite", steps)

    source = LF::Data::Schema::MigrationSourceGenerator.new.generate(
      plan,
      version: 202608301230_i64,
      name: "create_projects",
      class_name: "CreateProjects"
    )

    source.should contain("class CreateProjects < LF::Data::Migration")
    source.should contain("202608301230_i64")
    source.should contain(%(def name : String\n    "create_projects"))
    source.should contain(%(table.string("name", null: false, default: "Opal's project")))
    source.should contain("Time::Format::RFC_3339.parse")
    source.should contain("Bytes[0x0a, 0xff]")
    source.should contain("Bytes.new(0)")
    source.should contain(%(schema.rename_column("projects", "name", "title")))

    path = "/tmp/opal-generated-migration-#{Process.pid}.cr"
    begin
      data_entrypoint = File.expand_path("../../../src/opal/data", __DIR__)
      relative_entrypoint = Path[data_entrypoint]
        .relative_to(Path[path].parent)
        .to_s
      compilable = source.sub(
        %(require "opal/data"),
        %(require #{relative_entrypoint.inspect})
      )
      File.write(path, compilable)
      result = LF::DataSpecSupport.compile_fixture(path)
      result[:status].success?.should be_true, result[:error]
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "refuses unresolved, destructive, empty, and invalid generation requests" do
    generator = LF::Data::Schema::MigrationSourceGenerator.new
    destructive = LF::Data::Schema::DiffPlan.new(
      "sqlite",
      [LF::Data::Schema::DiffStep.destructive(
        LF::Data::Schema::DropTable.new("projects"),
        "drop table projects"
      )]
    )

    expect_raises(LF::Data::UnsafeSchemaChangeError) do
      generator.generate(
        destructive,
        version: 1_i64,
        name: "drop_projects",
        class_name: "DropProjects"
      )
    end
    generator.generate(
      destructive,
      version: 1_i64,
      name: "drop_projects",
      class_name: "DropProjects",
      allow_destructive: true
    ).should contain(%(schema.drop_table("projects")))

    expect_raises(LF::Data::EmptySchemaDiffError) do
      generator.generate(
        LF::Data::Schema::DiffPlan.new("sqlite"),
        version: 1_i64,
        name: "empty",
        class_name: "Empty"
      )
    end
    expect_raises(LF::Data::MigrationSourceGenerationError) do
      generator.generate(
        destructive,
        version: 0_i64,
        name: "drop_projects",
        class_name: "not a constant",
        allow_destructive: true
      )
    end
  end
end
