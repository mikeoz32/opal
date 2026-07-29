require "./spec_helper"
require "../../src/opal/data"
require "../../src/opal/data/dialects/sqlite"
require "./support/sqlite_database"
require "./support/sql_entity_manager"

@[LF::Data::Table("update_records")]
private class UpdateRecord
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : String

  property value : String
  property note : String?

  def initialize(@id : String, @value : String, @note : String?)
  end
end

private class UpdateListener
  include LF::Data::Listener

  getter statements = [] of LF::Data::StatementCompletionEvent

  def on_statement_completion(event : LF::Data::StatementCompletionEvent) : Nil
    @statements << event
  end
end

private def prepare_update_table(database : DB::Database)
  database.exec(
    "CREATE TABLE update_records " \
    "(id TEXT PRIMARY KEY, value TEXT NOT NULL, note TEXT)"
  )
  database.exec(
    "INSERT INTO update_records (id, value, note) VALUES (?, ?, ?)",
    "key",
    "before",
    nil
  )
end

describe LF::Data::EntityManager do
  it "updates a managed entity using values read at flush time" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      prepare_update_table(database)
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )

      source.transaction do |manager|
        entity = manager.find(UpdateRecord, "key").not_nil!
        entity.value = "scheduled"
        manager.persist(entity)
        entity.value = "at-flush"
        entity.note = "latest"
        manager.persist(entity)
      end

      database.query_one("SELECT value, note FROM update_records WHERE id = ?", "key") do |result|
        result.read(String).should eq("at-flush")
        result.read(String?).should eq("latest")
      end
    end
  end

  it "removes successful work from the queue before a later batch" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      prepare_update_table(database)
      listener = UpdateListener.new
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new,
        listeners: [listener] of LF::Data::Listener
      )

      source.transaction do |manager|
        entity = manager.find(UpdateRecord, "key").not_nil!
        entity.value = "first"
        manager.persist(entity)
        manager.flush
        manager.flush

        entity.value = "second"
        manager.persist(entity)
      end

      listener.statements.map(&.operation).should eq([
        LF::Data::StatementOperation::Select,
        LF::Data::StatementOperation::Update,
        LF::Data::StatementOperation::Update,
      ])
      database.scalar("SELECT value FROM update_records WHERE id = ?", "key")
        .should eq("second")
    end
  end

  it "fails when a managed row disappears before UPDATE" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      prepare_update_table(database)
      source = LF::DataSpecSupport::SQLEntityDataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )

      error = expect_raises(LF::Data::EntityStateError) do
        source.transaction do |base_manager|
          manager = base_manager.as(LF::DataSpecSupport::SQLEntityManager)
          entity = manager.find(UpdateRecord, "key").not_nil!
          manager.exec("DELETE FROM update_records WHERE id = ?", "key")
          entity.value = "missing"
          manager.persist(entity)
        end
      end

      error.operation.should eq(:update)
      database.scalar("SELECT count(*) FROM update_records").should eq(1_i64)
    end
  end
end
