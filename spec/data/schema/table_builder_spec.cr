require "../spec_helper"
require "../../../src/opal/data"

describe LF::Data::Schema::TableBuilder do
  it "builds every portable column type with typed defaults" do
    table = LF::Data::Schema::TableBuilder.new("todos")
    table.generated_id("id")
    table.string("title", null: false, default: "untitled")
    table.text("details")
    table.bool("completed", null: false, default: false)
    table.int32("priority", default: 1_i32)
    table.int64("version", null: false, default: 0_i64)
    table.float64("score", default: 1.5_f64)
    timestamp = Time.utc(2026, 7, 28)
    table.timestamp("created_at", default: timestamp)
    bytes = Bytes[1, 2, 3]
    table.bytes("payload", default: bytes)

    definition = table.build

    definition.name.should eq("todos")
    definition.columns.map(&.type).should eq([
      LF::Data::Schema::ColumnType::Int64,
      LF::Data::Schema::ColumnType::String,
      LF::Data::Schema::ColumnType::Text,
      LF::Data::Schema::ColumnType::Bool,
      LF::Data::Schema::ColumnType::Int32,
      LF::Data::Schema::ColumnType::Int64,
      LF::Data::Schema::ColumnType::Float64,
      LF::Data::Schema::ColumnType::Timestamp,
      LF::Data::Schema::ColumnType::Bytes,
    ])
    definition.columns.first.generated?.should be_true
    definition.columns.first.nullable?.should be_false
    definition.columns[1].default.not_nil!.value.should eq("untitled")
    definition.columns[2].default.should be_nil
    definition.columns[3].default.not_nil!.value.should be_false
    definition.columns[7].default.not_nil!.value.should eq(timestamp)
    definition.columns[8].default.not_nil!.value.should eq(bytes)
    definition.primary_key.not_nil!.columns.should eq(["id"])
  end

  it "builds primary, foreign, unique, and index definitions" do
    table = LF::Data::Schema::TableBuilder.new("tasks")
    table.int64("tenant_id", null: false)
    table.int64("id", null: false)
    table.string("slug", null: false)
    table.primary_key("tenant_id", "id", name: "pk_tasks")
    table.foreign_key(
      "tenant_id",
      references_table: "tenants",
      references_column: "id",
      name: "fk_tasks_tenant"
    )
    table.unique("tenant_id", "slug", name: "uq_tasks_slug")
    table.index("idx_tasks_slug", "slug")
    table.index("idx_tasks_identity", "tenant_id", "id", unique: true)

    definition = table.build

    definition.primary_key.not_nil!.name.should eq("pk_tasks")
    definition.foreign_keys.first.local_columns.should eq(["tenant_id"])
    definition.foreign_keys.first.referenced_table.should eq("tenants")
    definition.foreign_keys.first.referenced_columns.should eq(["id"])
    definition.unique_constraints.first.columns.should eq(["tenant_id", "slug"])
    definition.indexes.map(&.name).should eq([
      "idx_tasks_slug",
      "idx_tasks_identity",
    ])
    definition.indexes.last.unique?.should be_true
  end

  it "rejects empty and NUL identifiers" do
    expect_raises(ArgumentError, /identifier/) do
      LF::Data::Schema::TableBuilder.new("")
    end
    table = LF::Data::Schema::TableBuilder.new("todos")
    expect_raises(ArgumentError, /identifier/) { table.string("bad\0name") }
  end

  it "rejects duplicate columns" do
    table = LF::Data::Schema::TableBuilder.new("todos")
    table.string("title")

    expect_raises(ArgumentError, /Duplicate column.*title/) do
      table.text("title")
    end
  end

  it "rejects duplicate constraints and indexes" do
    table = LF::Data::Schema::TableBuilder.new("todos")
    table.int64("id")
    table.string("title")
    table.primary_key("id", name: "pk_todos")

    expect_raises(ArgumentError, /primary key/) do
      table.primary_key("title")
    end

    table.unique("title", name: "uq_todos_title")
    expect_raises(ArgumentError, /Duplicate constraint/) do
      table.unique("id", name: "uq_todos_title")
    end

    table.index("idx_todos_title", "title")
    expect_raises(ArgumentError, /Duplicate index/) do
      table.index("idx_todos_title", "id")
    end
  end

  it "rejects constraints and indexes with missing local columns" do
    table = LF::Data::Schema::TableBuilder.new("todos")
    table.int64("id")

    expect_raises(ArgumentError, /missing/) do
      table.foreign_key(
        "owner_id",
        references_table: "owners",
        references_column: "id"
      )
    end
    expect_raises(ArgumentError, /missing/) do
      table.unique("slug")
    end
    expect_raises(ArgumentError, /missing/) do
      table.index("idx_missing", "missing")
    end
  end

  it "rejects non-finite float defaults" do
    table = LF::Data::Schema::TableBuilder.new("measurements")

    expect_raises(ArgumentError, /finite/) do
      table.float64("value", default: Float64::NAN)
    end
  end

  it "rejects wrong default types at compile time" do
    fixture = File.expand_path("../../fixtures/data/schema_invalid_default.cr", __DIR__)
    result = LF::DataSpecSupport.compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain("String")
    result[:error].should contain("Bool")
  end

  it "represents every portable schema operation as a typed value" do
    table = LF::Data::Schema::TableBuilder.new("todos")
    table.generated_id("id")
    column = table.build.columns.first
    index = LF::Data::Schema::IndexDefinition.new(
      "idx_todos_id",
      ["id"],
      false
    )

    operations = [] of LF::Data::Schema::Operation
    operations << LF::Data::Schema::CreateTable.new(table.build)
    operations << LF::Data::Schema::DropTable.new("todos")
    operations << LF::Data::Schema::AddColumn.new("todos", column)
    operations << LF::Data::Schema::RenameColumn.new("todos", "old", "new")
    operations << LF::Data::Schema::CreateIndex.new("todos", index)
    operations << LF::Data::Schema::DropIndex.new("idx_todos_id")
    operations << LF::Data::Schema::RawSQL.new("backfill", "UPDATE todos SET id = id")

    operations.size.should eq(7)
    operations.last.as(LF::Data::Schema::RawSQL).name.should eq("backfill")
  end
end
