require "./spec_helper"
require "../../src/opal/data"
require "../../src/opal/data/dialects/sqlite"
require "./support/sqlite_database"
require "./support/sql_entity_manager"

@[LF::Data::Table("queue_records")]
private class QueueRecord
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : String

  property value : String

  def initialize(@id : String, @value : String)
  end
end

private class QueueListener
  include LF::Data::Listener

  getter statements = [] of LF::Data::StatementCompletionEvent

  def on_statement_completion(event : LF::Data::StatementCompletionEvent) : Nil
    @statements << event
  end
end

describe LF::Data::Internal::OperationQueue do
  it "executes mixed operations in first-scheduling order" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.exec(
        "CREATE TABLE queue_records (id TEXT PRIMARY KEY, value TEXT NOT NULL)"
      )
      database.exec("INSERT INTO queue_records VALUES (?, ?)", "a", "before-a")
      database.exec("INSERT INTO queue_records VALUES (?, ?)", "b", "before-b")
      listener = QueueListener.new
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new,
        listeners: [listener] of LF::Data::Listener
      )

      source.transaction do |manager|
        first = manager.find(QueueRecord, "a").not_nil!
        second = manager.find(QueueRecord, "b").not_nil!
        inserted = QueueRecord.new("c", "inserted")

        second.value = "unused-update"
        manager.persist(second)
        manager.persist(inserted)
        first.value = "updated"
        manager.persist(first)
        manager.remove(second)
      end

      writes = listener.statements.reject(&.operation.select?)
      writes.map(&.operation).should eq([
        LF::Data::StatementOperation::Delete,
        LF::Data::StatementOperation::Insert,
        LF::Data::StatementOperation::Update,
      ])
      database.scalar("SELECT count(*) FROM queue_records WHERE id = 'b'")
        .should eq(0_i64)
      database.scalar("SELECT value FROM queue_records WHERE id = 'c'")
        .should eq("inserted")
      database.scalar("SELECT value FROM queue_records WHERE id = 'a'")
        .should eq("updated")
    end
  end

  it "executes no statement for a cancelled new entity" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.exec(
        "CREATE TABLE queue_records (id TEXT PRIMARY KEY, value TEXT NOT NULL)"
      )
      listener = QueueListener.new
      source = LF::DataSpecSupport::SQLEntityDataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new,
        listeners: [listener] of LF::Data::Listener
      )

      source.transaction do |base_manager|
        manager = base_manager.as(LF::DataSpecSupport::SQLEntityManager)
        entity = QueueRecord.new("cancelled", "value")
        manager.persist(entity)
        manager.remove(entity)

        manager.queued_operations.should be_empty
      end

      listener.statements.should be_empty
      database.scalar("SELECT count(*) FROM queue_records").should eq(0_i64)
    end
  end
end
