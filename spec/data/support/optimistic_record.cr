require "../spec_helper"
require "../../../src/opal/data"
require "../../../src/opal/data/dialects/sqlite"
require "./sqlite_database"

@[LF::Data::Table("optimistic_records")]
class OptimisticRecord
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  property title : String

  @[LF::Data::Version]
  getter version : Int64 = 0_i64

  def initialize(@id : Int64, @title : String)
  end
end

def prepare_optimistic_records(database : DB::Database) : Nil
  database.exec(
    "CREATE TABLE optimistic_records (" \
    "id INTEGER PRIMARY KEY, title TEXT NOT NULL, version INTEGER NOT NULL)"
  )
end

def insert_optimistic_record(
  database : DB::Database,
  id : Int64,
  title : String,
  version : Int64 = 0_i64,
) : Nil
  database.exec(
    "INSERT INTO optimistic_records (id, title, version) VALUES (?, ?, ?)",
    id,
    title,
    version
  )
end

def optimistic_source(database : DB::Database) : LF::Data::DataSource
  LF::Data::DataSource.new(
    database,
    dialect: LF::Data::Dialects::SQLite.new
  )
end
