require "./spec_helper"
require "../../src/opal/data"
require "../../src/opal/data/dialects/sqlite"
require "./support/sqlite_database"
require "./support/sql_entity_manager"

@[LF::Data::Table("delete_records")]
private class DeleteRecord
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : String

  getter value : String

  def initialize(@id : String, @value : String)
  end
end

private class DeleteListener
  include LF::Data::Listener

  getter statements = [] of LF::Data::StatementCompletionEvent

  def on_statement_completion(event : LF::Data::StatementCompletionEvent) : Nil
    @statements << event
  end
end

private def prepare_delete_table(database : DB::Database)
  database.exec(
    "CREATE TABLE delete_records (id TEXT PRIMARY KEY, value TEXT NOT NULL)"
  )
  database.exec(
    "INSERT INTO delete_records (id, value) VALUES (?, ?)",
    "key",
    "value"
  )
end

describe LF::Data::EntityManager do
  it "deletes a managed entity and detaches it after flush" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      prepare_delete_table(database)
      source = LF::DataSpecSupport::SQLEntityDataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )
      entity = nil.as(DeleteRecord?)

      source.transaction do |base_manager|
        manager = base_manager.as(LF::DataSpecSupport::SQLEntityManager)
        entity = manager.find(DeleteRecord, "key").not_nil!
        manager.remove(entity.not_nil!)
        manager.flush

        manager.state_of(entity.not_nil!).should eq(LF::Data::EntityState::Detached)
        expect_raises(LF::Data::DetachedEntityError) do
          manager.persist(entity.not_nil!)
        end
      end

      database.scalar("SELECT count(*) FROM delete_records").should eq(0_i64)
    end
  end

  it "rejects a delete that affects more than one row" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.exec("CREATE TABLE delete_records (id TEXT, value TEXT NOT NULL)")
      database.exec("INSERT INTO delete_records (id, value) VALUES (?, ?)", "dup", "first")
      database.exec("INSERT INTO delete_records (id, value) VALUES (?, ?)", "dup", "second")
      source = LF::Data::DataSource.new(database, dialect: LF::Data::Dialects::SQLite.new)

      error = expect_raises(LF::Data::EntityStateError) do
        source.transaction do |manager|
          entity = DeleteRecord.new("dup", "third")
          manager.persist(entity)
          manager.flush
          manager.remove(entity)
          manager.flush
        end
      end

      error.operation.should eq(:delete)
    ensure
      source.try &.close
    end
  end

  it "reports one DELETE and removes the identity-map entry" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      prepare_delete_table(database)
      listener = DeleteListener.new
      source = LF::Data::DataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new,
        listeners: [listener] of LF::Data::Listener
      )

      source.transaction do |manager|
        entity = manager.find(DeleteRecord, "key").not_nil!
        manager.remove(entity)
      end

      listener.statements.map(&.operation).should eq([
        LF::Data::StatementOperation::Select,
        LF::Data::StatementOperation::Delete,
      ])
      listener.statements.last.rows_affected.should eq(1_i64)
    end
  end

  it "fails when a managed row disappears before DELETE" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      prepare_delete_table(database)
      source = LF::DataSpecSupport::SQLEntityDataSource.new(
        database,
        dialect: LF::Data::Dialects::SQLite.new
      )

      error = expect_raises(LF::Data::EntityStateError) do
        source.transaction do |base_manager|
          manager = base_manager.as(LF::DataSpecSupport::SQLEntityManager)
          entity = manager.find(DeleteRecord, "key").not_nil!
          manager.exec("DELETE FROM delete_records WHERE id = ?", "key")
          manager.remove(entity)
        end
      end

      error.operation.should eq(:delete)
      database.scalar("SELECT count(*) FROM delete_records").should eq(1_i64)
    end
  end
end
