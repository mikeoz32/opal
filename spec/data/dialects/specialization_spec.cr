require "../spec_helper"
require "../../../src/opal/data/dialects/sqlite"

module DialectSpecializationSpec
  @[LF::Data::Table("first_shapes")]
  class First
    @[LF::Data::Id]
    getter id : Int64

    getter value : String

    def initialize(@id, @value)
    end
  end

  @[LF::Data::Table("second_shapes")]
  class Second
    @[LF::Data::Id]
    getter id : Int64

    getter enabled : Bool

    def initialize(@id, @enabled)
    end
  end

  module Domain
    class AuditEvent
      @[LF::Data::Id]
      getter id : Int64

      getter payload : String

      def initialize(@id, @payload)
      end
    end
  end
end

describe "static dialect specialization" do
  it "keeps stable independent SQL for each entity shape" do
    dialect = LF::Data::Dialects::SQLite.new

    first_sql = dialect.insert_plan(DialectSpecializationSpec::First).sql
    repeated_sql = dialect.insert_plan(DialectSpecializationSpec::First).sql
    second_sql = dialect.insert_plan(DialectSpecializationSpec::Second).sql

    repeated_sql.should eq(first_sql)
    first_sql.should eq(%(INSERT INTO "first_shapes" ("id", "value") VALUES (?, ?)))
    second_sql.should eq(%(INSERT INTO "second_shapes" ("id", "enabled") VALUES (?, ?)))
  end

  it "derives a default table name from the unqualified entity name" do
    dialect = LF::Data::Dialects::SQLite.new

    dialect.find_plan(DialectSpecializationSpec::Domain::AuditEvent).sql.should eq(
      %(SELECT "id", "payload" FROM "audit_event" WHERE "id" = ?)
    )
  end

  it "compiles generic dispatch through the abstract dialect contract" do
    fixture = File.expand_path("../../fixtures/data/dialect_virtual_generic_dispatch.cr", __DIR__)
    result = LF::DataSpecSupport.compile_fixture(fixture)

    result[:status].success?.should be_true
    result[:error].should eq("")
  end

  it "keeps runtime SQL assembly and framework caches out of static plans" do
    fixture = File.expand_path("../../fixtures/data/dialect_virtual_generic_dispatch.cr", __DIR__)
    expansion = LF::DataSpecSupport.compile_fixture_ir(fixture)
    source = File.read(
      File.expand_path("../../../src/opal/data/sql/static_plan_compiler.cr", __DIR__)
    )

    expansion[:status].success?.should be_true
    expansion[:error].should eq("")
    expansion[:ir].should contain(
      "SELECT \\22id\\22, \\22name\\22 FROM \\22compile_first\\22 WHERE \\22id\\22 = ?"
    )
    source.should_not contain("String::Builder")
    source.should_not contain("Array(DB::Any)")
    source.should_not contain("BindSlot")
    source.should_not contain("PlanCache")
  end
end
