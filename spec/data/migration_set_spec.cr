require "./spec_helper"
require "../../src/opal/data"

private class MigrationSetProbe < LF::Data::Migration
  def initialize(@version : Int64, @name : String)
  end

  def version : Int64
    @version
  end

  def name : String
    @name
  end

  def up(schema : LF::Data::SchemaEditor) : Nil
  end
end

describe LF::Data::MigrationSet do
  it "retains explicit migration instances in declared order" do
    first = MigrationSetProbe.new(1_i64, "first")
    second = MigrationSetProbe.new(2_i64, "second")

    migrations = LF::Data::MigrationSet.new(first, second)

    migrations.to_a.should eq([first, second])
    migrations.size.should eq(2)
    migrations.empty?.should be_false
    migrations.responds_to?(:migrations).should be_false
  end

  it "accepts an explicit empty set" do
    migrations = LF::Data::MigrationSet.new

    migrations.empty?.should be_true
    migrations.validate!
  end

  {
    {0_i64, "zero"},
    {-1_i64, "negative"},
  }.each do |version, name|
    it "rejects non-positive version #{version}" do
      error = expect_raises(LF::Data::MigrationError) do
        LF::Data::MigrationSet.new(MigrationSetProbe.new(version, name))
      end

      error.reason.should eq(:invalid_version)
      error.version.should eq(version)
      error.migration_name.should eq(name)
    end
  end

  it "rejects an empty migration name" do
    error = expect_raises(LF::Data::MigrationError) do
      LF::Data::MigrationSet.new(MigrationSetProbe.new(1_i64, ""))
    end

    error.reason.should eq(:empty_name)
    error.version.should eq(1_i64)
    error.migration_name.should eq("")
  end

  it "reports both names for a duplicate version" do
    error = expect_raises(LF::Data::DuplicateMigrationVersionError) do
      LF::Data::MigrationSet.new(
        MigrationSetProbe.new(1_i64, "create_todos"),
        MigrationSetProbe.new(1_i64, "rename_todos")
      )
    end

    error.version.should eq(1_i64)
    error.migration_name.should eq("create_todos")
    error.conflicting_name.should eq("rename_todos")
  end

  it "reports both migrations when versions are not strictly ascending" do
    error = expect_raises(LF::Data::MigrationOrderError) do
      LF::Data::MigrationSet.new(
        MigrationSetProbe.new(2_i64, "second"),
        MigrationSetProbe.new(1_i64, "first")
      )
    end

    error.previous_version.should eq(2_i64)
    error.previous_name.should eq("second")
    error.version.should eq(1_i64)
    error.migration_name.should eq("first")
  end

  it "can be revalidated before database access" do
    migrations = LF::Data::MigrationSet.new(
      MigrationSetProbe.new(1_i64, "first"),
      MigrationSetProbe.new(2_i64, "second")
    )

    migrations.validate!
  end
end
