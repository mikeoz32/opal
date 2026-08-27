require "./spec_helper"
require "../../src/opal/data"
require "../../src/opal/data/dialects/sqlite"

private module DowncaseConverter
  def self.load(result : DB::ResultSet) : String
    result.read(String).upcase
  end

  def self.dump(value : String) : String
    value.downcase
  end
end

@[LF::Data::Table("entity_sql_assigned")]
private class EntitySQLAssigned
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : String

  @[LF::Data::Column(name: "stored_title", converter: DowncaseConverter)]
  getter title : String

  getter note : String?

  @[LF::Data::Column(ignore: true)]
  getter transient : Int32 = 1

  def initialize(@id : String, @title : String, @note : String?)
  end
end

@[LF::Data::Table("entity_sql_generated")]
private class EntitySQLGenerated
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  getter value : Int32

  def initialize(@value : Int32)
    @id = nil
  end
end

private class EntitySQLGeneratedOnly
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  def initialize
    @id = nil
  end
end

describe LF::Data::Entity do
  it "generates exact direct INSERT, UPDATE, and DELETE tuples" do
    entity = EntitySQLAssigned.new("key-1", "MixedCase", nil)

    entity.__lf_insert_args.should eq({"key-1", "mixedcase", nil})
    entity.__lf_insert_args.should be_a(Tuple(String, String, String?))
    entity.__lf_update_args.should eq({"mixedcase", nil, "key-1"})
    entity.__lf_delete_args.should eq({"key-1"})
    EntitySQLAssigned.__lf_find_args("key-1").should eq({"key-1"})
  end

  it "excludes generated IDs from INSERT and includes them in predicates" do
    entity = EntitySQLGenerated.new(42)

    entity.__lf_insert_args.should eq({42})
    entity.__lf_update_args.should eq({42, nil})
    entity.__lf_delete_args.should eq({nil})

    entity.__lf_write_generated_id(7_i64)

    entity.__lf_update_args.should eq({42, 7_i64})
    entity.__lf_delete_args.should eq({7_i64})
  end

  it "generates an empty INSERT tuple for an entity with only a generated ID" do
    EntitySQLGeneratedOnly.new.__lf_insert_args.should eq(Tuple.new)
  end

  it "keeps generated tuple order aligned with static SQL placeholder order" do
    dialect = LF::Data::Dialects::SQLite.new
    entity = EntitySQLAssigned.new("key-1", "MixedCase", "note")

    {
      dialect.insert_plan(EntitySQLAssigned).sql => entity.__lf_insert_args,
      dialect.update_plan(EntitySQLAssigned).sql => entity.__lf_update_args,
      dialect.delete_plan(EntitySQLAssigned).sql => entity.__lf_delete_args,
      dialect.find_plan(EntitySQLAssigned).sql   => EntitySQLAssigned.__lf_find_args("key-1"),
    }.each do |sql, arguments|
      sql.count('?').should eq(arguments.size)
    end
  end

  it "does not build runtime bind arrays or slots" do
    source = File.read(File.expand_path("../../src/opal/data/entity.cr", __DIR__))

    source.should_not contain("Array(DB::Any)")
    source.should_not contain("BindSlot")
  end

end
