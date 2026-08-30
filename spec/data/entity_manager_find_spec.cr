require "./spec_helper"
require "../../src/opal/data"
require "../../src/opal/data/dialects/sqlite"
require "./support/sqlite_database"

@[LF::Data::Table("find_records")]
private class FindRecord
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : String

  getter value : String

  def initialize(@id : String, @value : String)
  end
end

@[LF::Data::Table("generated_find_records")]
private class GeneratedFindRecord
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  getter value : String

  def initialize(@value : String)
    @id = nil
  end
end

@[LF::Data::Table("other_find_records")]
private class OtherFindRecord
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : String

  getter value : String

  def initialize(@id : String, @value : String)
  end
end

private record FindDomainId, value : String

private module FindDomainIdConverter
  def self.load(result : DB::ResultSet) : FindDomainId
    FindDomainId.new(result.read(String))
  end

  def self.dump(value : FindDomainId) : String
    value.value
  end
end

@[LF::Data::Table("converted_find_records")]
private class ConvertedFindRecord
  include LF::Data::Entity

  @[LF::Data::Id]
  @[LF::Data::Column(converter: FindDomainIdConverter)]
  getter id : FindDomainId

  property value : String

  def initialize(@id : FindDomainId, @value : String)
  end
end

private class FindListener
  include LF::Data::Listener

  getter statements = [] of LF::Data::StatementCompletionEvent

  def on_statement_completion(event : LF::Data::StatementCompletionEvent) : Nil
    @statements << event
  end
end

private class MismatchedFindDialect < LF::Data::Dialects::SQLite
  def find_plan(entity : T.class) : LF::Data::SQL::StatementPlan forall T
    LF::Data::SQL::StatementPlan.new(
      "SELECT id AS wrong_id, value FROM find_records WHERE id = ?"
    )
  end
end

private def with_find_database(& : DB::Database, FindListener ->)
  LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
    database.exec("CREATE TABLE find_records (id TEXT, value TEXT NOT NULL)")
    database.exec(
      "CREATE TABLE generated_find_records " \
      "(id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT NOT NULL)"
    )
    database.exec("CREATE TABLE other_find_records (id TEXT, value TEXT NOT NULL)")
    database.exec("CREATE TABLE converted_find_records (id TEXT, value TEXT NOT NULL)")
    listener = FindListener.new
    yield database, listener
  end
end

describe LF::Data::EntityManager do
  it "returns nil for no row and reports one SELECT" do
    with_find_database do |database, listener|
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new,
        listeners: [listener] of LF::Data::Listener
      )
      result = source.transaction { |manager| manager.find(FindRecord, "missing") }

      result.should be_nil
      listener.statements.map(&.operation).should eq([LF::Data::StatementOperation::Select])
      listener.statements.first.rows_affected.should eq(0_i64)
    end
  end

  it "hydrates assigned and generated IDs" do
    with_find_database do |database, listener|
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new,
        listeners: [listener] of LF::Data::Listener
      )
      database.exec("INSERT INTO find_records (id, value) VALUES (?, ?)", "key", "assigned")
      database.exec("INSERT INTO generated_find_records (value) VALUES (?)", "generated")
      generated_id = database.scalar("SELECT last_insert_rowid()").as(Int64)

      assigned = source.transaction { |manager| manager.find(FindRecord, "key") }
      generated = source.transaction do |manager|
        manager.find(GeneratedFindRecord, generated_id)
      end

      assigned.not_nil!.value.should eq("assigned")
      loaded_generated = generated.not_nil!
      loaded_generated.id.should eq(generated_id)
      loaded_generated.value.should eq("generated")
    end
  end

  it "returns the same managed object without a second SELECT" do
    with_find_database do |database, listener|
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new,
        listeners: [listener] of LF::Data::Listener
      )
      database.exec("INSERT INTO find_records (id, value) VALUES (?, ?)", "key", "stored")

      source.transaction do |manager|
        first = manager.find(FindRecord, "key").not_nil!
        second = manager.find(FindRecord, "key").not_nil!

        second.same?(first).should be_true
      end

      listener.statements.size.should eq(1)
    end
  end

  it "separates equal database IDs belonging to different entity types" do
    with_find_database do |database, listener|
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new,
        listeners: [listener] of LF::Data::Listener
      )
      database.exec("INSERT INTO find_records (id, value) VALUES (?, ?)", "same", "first")
      database.exec(
        "INSERT INTO other_find_records (id, value) VALUES (?, ?)",
        "same",
        "second"
      )

      source.transaction do |manager|
        first = manager.find(FindRecord, "same").not_nil!
        second = manager.find(OtherFindRecord, "same").not_nil!

        first.value.should eq("first")
        second.value.should eq("second")
      end
    end
  end

  it "uses the application-facing converted ID for lookup and identity" do
    with_find_database do |database, listener|
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new,
        listeners: [listener] of LF::Data::Listener
      )
      database.exec(
        "INSERT INTO converted_find_records (id, value) VALUES (?, ?)",
        "domain-key",
        "stored"
      )

      source.transaction do |manager|
        id = FindDomainId.new("domain-key")
        first = manager.find(ConvertedFindRecord, id).not_nil!
        second = manager.find(ConvertedFindRecord, id).not_nil!

        first.id.should eq(id)
        second.should be(first)
        listener.statements.size.should eq(1)

        first.value = "updated"
        manager.persist(first)
      end

      database.scalar(
        "SELECT value FROM converted_find_records WHERE id = ?",
        "domain-key"
      ).should eq("updated")

      source.transaction do |manager|
        manager.delete(ConvertedFindRecord, FindDomainId.new("domain-key")).should be_true
      end

      database.scalar("SELECT count(*) FROM converted_find_records").should eq(0_i64)
    end
  end

  it "deletes assigned and generated entities by their non-nil lookup IDs" do
    with_find_database do |database, listener|
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new,
        listeners: [listener] of LF::Data::Listener
      )
      database.exec("INSERT INTO find_records (id, value) VALUES (?, ?)", "key", "assigned")
      database.exec("INSERT INTO generated_find_records (value) VALUES (?)", "generated")
      generated_id = database.scalar("SELECT last_insert_rowid()").as(Int64)

      source.transaction do |manager|
        manager.delete(FindRecord, "key").should be_true
        manager.delete(GeneratedFindRecord, generated_id).should be_true
        manager.delete(FindRecord, "missing").should be_false
      end

      database.scalar("SELECT count(*) FROM find_records").should eq(0_i64)
      database.scalar("SELECT count(*) FROM generated_find_records").should eq(0_i64)
    end
  end

  it "rejects more than one row for an ID" do
    with_find_database do |database, listener|
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new,
        listeners: [listener] of LF::Data::Listener
      )
      database.exec("INSERT INTO find_records (id, value) VALUES (?, ?)", "dup", "first")
      database.exec("INSERT INTO find_records (id, value) VALUES (?, ?)", "dup", "second")

      error = expect_raises(LF::Data::NonUniqueResultError) do
        source.transaction { |manager| manager.find(FindRecord, "dup") }
      end

      error.entity_name.should eq("FindRecord")
      error.rows.should eq(2_i64)
    end
  end

  it "propagates strict hydration failures without registering the entity" do
    with_find_database do |database, listener|
      database.exec("INSERT INTO find_records (id, value) VALUES (?, ?)", "key", "value")
      source = LF::Data::DataSource.new(
        database,
        dialect: MismatchedFindDialect.new,
        listeners: [listener] of LF::Data::Listener
      )

      error = expect_raises(LF::Data::MappingError) do
        source.transaction { |manager| manager.find(FindRecord, "key") }
      end

      error.entity.should eq("FindRecord")
      error.column.should eq("wrong_id")
      listener.statements.size.should eq(1)
      listener.statements.first.error.should be(error)
    end
  end
end
