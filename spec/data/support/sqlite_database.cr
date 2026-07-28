require "sqlite3"
require "./temp_path"

module LF::DataSpecSupport
  module SQLiteDatabase
    extend self

    IDENTIFIER = /\A[a-zA-Z_][a-zA-Z0-9_]*\z/

    def with_memory(&block : DB::Database -> T) : T forall T
      DB.open("sqlite3://%3Amemory%3A") do |db|
        yield db
      end
    end

    def with_file(&block : DB::Database, String -> T) : T forall T
      path = TempPath.database

      begin
        DB.open("sqlite3:#{path}") do |db|
          yield db, path
        end
      ensure
        TempPath.cleanup_database(path)
      end
    end

    def assert_table_exists!(db : DB::Database, table : String) : Nil
      ensure_identifier(table)
      exists = db.scalar(
        "select count(*) from sqlite_master where type = 'table' and name = ?",
        table
      ).as(Int64)
      raise "Expected table #{table.inspect} to exist" unless exists == 1
    end

    def assert_table_missing!(db : DB::Database, table : String) : Nil
      ensure_identifier(table)
      exists = db.scalar(
        "select count(*) from sqlite_master where type = 'table' and name = ?",
        table
      ).as(Int64)
      raise "Expected table #{table.inspect} to be absent" unless exists == 0
    end

    def assert_row_count!(db : DB::Database, table : String, expected : Int64) : Nil
      ensure_identifier(table)
      actual = db.scalar("select count(*) from \"#{table}\"").as(Int64)
      raise "Expected #{table.inspect} to contain #{expected} rows, got #{actual}" unless actual == expected
    end

    private def ensure_identifier(identifier : String) : Nil
      raise ArgumentError.new("Invalid SQLite test identifier: #{identifier.inspect}") unless IDENTIFIER.matches?(identifier)
    end
  end
end
