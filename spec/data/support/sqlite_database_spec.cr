require "../spec_helper"
require "./sqlite_database"
require "./sql_recorder"
require "./temp_path"

describe "Data SQLite test support" do
  it "opens a fresh in-memory database for every example" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |db|
      db.exec("create table todos (id integer)")
      db.exec("insert into todos values (1)")
      LF::DataSpecSupport::SQLiteDatabase.assert_table_exists!(db, "todos")
      LF::DataSpecSupport::SQLiteDatabase.assert_row_count!(db, "todos", 1)
    end

    LF::DataSpecSupport::SQLiteDatabase.with_memory do |db|
      LF::DataSpecSupport::SQLiteDatabase.assert_table_missing!(db, "todos")
    end
  end

  it "cleans a file database and sidecars after an exception" do
    path = ""

    expect_raises(Exception, "boom") do
      LF::DataSpecSupport::SQLiteDatabase.with_file do |db, database_path|
        path = database_path
        db.exec("create table todos (id integer)")
        File.touch("#{path}-wal")
        File.touch("#{path}-shm")
        raise "boom"
      end
    end

    File.exists?(path).should be_false
    File.exists?("#{path}-wal").should be_false
    File.exists?("#{path}-shm").should be_false
  end

  it "generates unique process-scoped database paths" do
    first = LF::DataSpecSupport::TempPath.database
    second = LF::DataSpecSupport::TempPath.database

    first.should_not eq(second)
    first.should match(/^\/tmp\/opal-data-#{Process.pid}-[0-9a-f]+\.db$/)
  end

  it "records SQL statements in order with their arguments" do
    recorder = LF::DataSpecSupport::SQLRecorder.new

    recorder.record("select 1")
    recorder.record("select ?", 2)

    recorder.statements.map(&.sql).should eq(["select 1", "select ?"])
    recorder.statements[1].args.should eq([2] of DB::Any)
  end
end
