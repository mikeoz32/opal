require "../../spec_helper"
require "../../../../src/opal/data/dialects/sqlite"
require "../../support/sqlite_database"

private def sqlite_schema_editor(
  connection : DB::Connection,
  events : Array(LF::Data::StatementCompletionEvent)? = nil,
) : LF::Data::SchemaEditor
  observer = if captured = events
               ->(event : LF::Data::StatementCompletionEvent) do
                 captured << event
                 nil
               end
             end
  renderer = LF::Data::Dialects::SQLite.new.schema_renderer(connection)
  LF::Data::SchemaEditor.new(renderer, observer)
end

describe LF::Data::Dialects::SQLite::SchemaRenderer do
  it "creates a table idempotently when requested" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.using_connection do |connection|
        events = [] of LF::Data::StatementCompletionEvent
        schema = sqlite_schema_editor(connection, events)

        2.times do
          schema.create_table("settings", if_not_exists: true) do |table|
            table.string("name", null: false)
            table.index("idx_settings_name", "name")
          end
        end

        events.map(&.sql).should eq([
          %(CREATE TABLE IF NOT EXISTS "settings" ("name" VARCHAR(255) NOT NULL)),
          %(CREATE INDEX IF NOT EXISTS "idx_settings_name" ON "settings" ("name")),
          %(CREATE TABLE IF NOT EXISTS "settings" ("name" VARCHAR(255) NOT NULL)),
          %(CREATE INDEX IF NOT EXISTS "idx_settings_name" ON "settings" ("name")),
        ])
      end
    end
  end

  it "creates a table with portable columns, constraints, defaults, and indexes" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.using_connection do |connection|
        events = [] of LF::Data::StatementCompletionEvent
        schema = sqlite_schema_editor(connection, events)
        timestamp = Time.utc(2026, 7, 28, 12, 30, 0)

        schema.create_table("projects") do |table|
          table.generated_id("id")
          table.string("code", null: false, default: "can't")
          table.text("notes")
          table.bool("active", null: false, default: true)
          table.int32("priority", default: 2_i32)
          table.int64("version", null: false, default: 0_i64)
          table.float64("score", default: 1.5_f64)
          table.timestamp("created_at", default: timestamp)
          table.bytes("payload", default: Bytes[0x0a, 0xff])
          table.unique("code", name: "uq_projects_code")
          table.index("idx_projects_active", "active")
        end

        create_table_sql = [
          "CREATE TABLE \"projects\" (",
          "\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, ",
          "\"code\" VARCHAR(255) NOT NULL DEFAULT 'can''t', ",
          "\"notes\" TEXT, \"active\" INTEGER NOT NULL DEFAULT 1, ",
          "\"priority\" INTEGER DEFAULT 2, \"version\" INTEGER NOT NULL DEFAULT 0, ",
          "\"score\" REAL DEFAULT 1.5, ",
          "\"created_at\" TEXT DEFAULT '2026-07-28T12:30:00Z', ",
          "\"payload\" BLOB DEFAULT X'0aff', ",
          "CONSTRAINT \"uq_projects_code\" UNIQUE (\"code\"))",
        ].join
        events.map(&.sql).should eq([
          create_table_sql,
          %(CREATE INDEX "idx_projects_active" ON "projects" ("active")),
        ])
        events.each do |event|
          event.operation.should eq(LF::Data::StatementOperation::Schema)
          event.error.should be_nil
        end
        connection.scalar(
          "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
          "projects"
        ).should eq(1_i64)
        connection.scalar(
          "SELECT count(*) FROM pragma_table_info('projects')"
        ).should eq(9_i64)
        connection.scalar(
          "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = ?",
          "idx_projects_active"
        ).should eq(1_i64)
      end
    end
  end

  it "renders foreign and composite primary key constraints" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.using_connection do |connection|
        connection.exec("PRAGMA foreign_keys = ON")
        connection.exec("CREATE TABLE tenants (id INTEGER PRIMARY KEY)")
        events = [] of LF::Data::StatementCompletionEvent
        schema = sqlite_schema_editor(connection, events)

        schema.create_table("tasks") do |table|
          table.int64("tenant_id", null: false)
          table.int64("id", null: false)
          table.primary_key("tenant_id", "id", name: "pk_tasks")
          table.foreign_key(
            "tenant_id",
            references_table: "tenants",
            references_column: "id",
            name: "fk_tasks_tenant"
          )
        end

        events.first.sql.should eq([
          "CREATE TABLE \"tasks\" (",
          "\"tenant_id\" INTEGER NOT NULL, \"id\" INTEGER NOT NULL, ",
          "CONSTRAINT \"pk_tasks\" PRIMARY KEY (\"tenant_id\", \"id\"), ",
          "CONSTRAINT \"fk_tasks_tenant\" FOREIGN KEY (\"tenant_id\") ",
          "REFERENCES \"tenants\" (\"id\"))",
        ].join)
        connection.scalar(
          "SELECT count(*) FROM pragma_foreign_key_list('tasks')"
        ).should eq(1_i64)
      end
    end
  end

  it "executes add, rename, index, raw SQL, and drop operations exactly" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.using_connection do |connection|
        events = [] of LF::Data::StatementCompletionEvent
        schema = sqlite_schema_editor(connection, events)
        schema.create_table("todos") { |table| table.generated_id("id") }
        schema.add_column("todos") do |table|
          table.bool("completed", null: false, default: false)
        end
        schema.rename_column("todos", "completed", "done")
        schema.create_index("todos", "idx_todos_done", "done", unique: true)
        schema.raw("seed_todos", "INSERT INTO todos (done) VALUES (1)")
        schema.drop_index("idx_todos_done")
        schema.drop_table("todos")

        events.map { |event| {event.entity_name, event.sql} }.should eq([
          {"todos", %(CREATE TABLE "todos" ("id" INTEGER PRIMARY KEY AUTOINCREMENT))},
          {"todos", %(ALTER TABLE "todos" ADD COLUMN "completed" INTEGER NOT NULL DEFAULT 0)},
          {"todos", %(ALTER TABLE "todos" RENAME COLUMN "completed" TO "done")},
          {"idx_todos_done", %(CREATE UNIQUE INDEX "idx_todos_done" ON "todos" ("done"))},
          {"seed_todos", "INSERT INTO todos (done) VALUES (1)"},
          {"idx_todos_done", %(DROP INDEX "idx_todos_done")},
          {"todos", %(DROP TABLE "todos")},
        ])
        events[4].rows_affected.should eq(1_i64)
        LF::DataSpecSupport::SQLiteDatabase.assert_table_missing!(database, "todos")
      end
    end
  end

  it "quotes identifiers through the SQLite dialect" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.using_connection do |connection|
        events = [] of LF::Data::StatementCompletionEvent
        schema = sqlite_schema_editor(connection, events)

        schema.create_table("quoted\"table") do |table|
          table.int64("select\"value")
        end

        events.first.sql.should eq(
          %(CREATE TABLE "quoted""table" ("select""value" INTEGER))
        )
      end
    end
  end

  it "rejects unsupported generated ADD COLUMN before executing SQL" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.using_connection do |connection|
        connection.exec("CREATE TABLE todos (id INTEGER PRIMARY KEY)")
        renderer = LF::Data::Dialects::SQLite.new.schema_renderer(connection)
        column = LF::Data::Schema::ColumnDefinition.new(
          "other_id",
          LF::Data::Schema::ColumnType::Int64,
          false,
          nil,
          true
        )

        error = expect_raises(LF::Data::UnsupportedSchemaOperationError) do
          renderer.execute(LF::Data::Schema::AddColumn.new("todos", column))
        end

        error.dialect.should eq("sqlite")
        connection.scalar(
          "SELECT count(*) FROM pragma_table_info('todos')"
        ).should eq(1_i64)
      end
    end
  end

  it "preserves database errors and reports the failed schema statement" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.using_connection do |connection|
        events = [] of LF::Data::StatementCompletionEvent
        schema = sqlite_schema_editor(connection, events)

        error = expect_raises(SQLite3::Exception) do
          schema.drop_table("missing_table")
        end

        error.should_not be_a(LF::Data::Error)
        events.size.should eq(1)
        events.first.sql.should eq(%(DROP TABLE "missing_table"))
        events.first.error.should be(error)
      end
    end
  end
end
