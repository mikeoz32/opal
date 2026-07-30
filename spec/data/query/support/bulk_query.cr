require "../../spec_helper"
require "../../../../src/opal/data"
require "../../../../src/opal/data/dialects/sqlite"
require "../../support/sqlite_database"

@[LF::Data::Table("bulk_query_records")]
class BulkQueryRecord
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  property title : String
  property active : Bool

  @[LF::Data::Version]
  getter version : Int64

  def initialize(@id, @title, @active, @version)
  end
end

class OtherBulkQueryRecord
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  getter title : String

  def initialize(@id, @title)
  end
end

class BulkQueryListener
  include LF::Data::Listener

  getter statements = [] of LF::Data::StatementCompletionEvent

  def on_statement_completion(event : LF::Data::StatementCompletionEvent) : Nil
    @statements << event
  end
end

def with_bulk_query_source(& : DB::Database, LF::Data::DataSource, BulkQueryListener ->)
  LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
    database.exec(
      "CREATE TABLE bulk_query_records (" \
      "id INTEGER PRIMARY KEY, title TEXT NOT NULL, " \
      "active INTEGER NOT NULL, version INTEGER NOT NULL)"
    )
    {
      {1_i64, "one", true, 0_i64},
      {2_i64, "two", false, 0_i64},
      {3_i64, "three", true, 0_i64},
    }.each do |row|
      database.exec(
        "INSERT INTO bulk_query_records (id, title, active, version) " \
        "VALUES (?, ?, ?, ?)",
        *row
      )
    end
    listener = BulkQueryListener.new
    source = LF::Data::DataSource.new(
      database,
      dialect: LF::Data::Dialects::SQLite.new,
      listeners: [listener] of LF::Data::Listener
    )
    yield database, source, listener
  ensure
    source.try &.close
  end
end
