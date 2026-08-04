module LF
  module Data
    class MigrationHistory
      TABLE_NAME = "_lf_migrations"

      record Entry,
        version : Int64,
        name : String,
        applied_at : Time

      def initialize(
        @connection : DB::Connection,
        @dialect : Dialect,
        @observer : StatementObserver? = nil,
      )
      end

      def ensure_table : Nil
        schema = SchemaEditor.new(@dialect.schema_renderer(@connection), @observer)
        schema.create_table(TABLE_NAME, if_not_exists: true) do |table|
          table.int64("version", null: false)
          table.text("name", null: false)
          table.timestamp("applied_at", null: false)
          table.primary_key("version")
        end
      end

      def record(migration : Migration, applied_at : Time = Time.utc) : Nil
        columns = %w(version name applied_at).map { |column| quote(column) }
        placeholders = (1..columns.size).map { |position| @dialect.placeholder(position) }
        sql = "INSERT INTO #{quote(TABLE_NAME)} (#{columns.join(", ")}) " \
              "VALUES (#{placeholders.join(", ")})"
        arguments = {
          migration.version,
          migration.name,
          applied_at.to_rfc3339,
        }
        return @connection.exec(sql, *arguments) unless @observer

        started_at = Time.instant
        rows = nil.as(Int64?)
        statement_error = nil.as(Exception?)
        begin
          result = @connection.exec(sql, *arguments)
          rows = result.rows_affected
        rescue error
          statement_error = error
          raise error
        ensure
          notify(
            StatementCompletionEvent.new(
              StatementOperation::Insert,
              TABLE_NAME,
              sql,
              Time.instant - started_at,
              rows,
              statement_error
            )
          )
        end
      end

      def load : Array(Entry)
        entries = [] of Entry
        columns = %w(version name applied_at).map { |column| quote(column) }
        sql = "SELECT #{columns.join(", ")} FROM #{quote(TABLE_NAME)} " \
              "ORDER BY #{quote("version")}"
        unless @observer
          append_entries(sql, entries)
          return entries
        end

        started_at = Time.instant
        rows = 0_i64
        statement_error = nil.as(Exception?)
        begin
          rows = append_entries(sql, entries)
        rescue error
          statement_error = error
          raise error
        ensure
          notify(
            StatementCompletionEvent.new(
              StatementOperation::Select,
              TABLE_NAME,
              sql,
              Time.instant - started_at,
              rows,
              statement_error
            )
          )
        end
        entries
      end

      private def append_entries(sql : String, entries : Array(Entry)) : Int64
        rows = 0_i64
        @connection.query(sql) do |result|
          while result.move_next
            rows += 1
            entries << Entry.new(
              result.read(Int64),
              result.read(String),
              Time.parse_rfc3339(result.read(String))
            )
          end
        end
        rows
      end

      def pending(migrations : MigrationSet) : Array(Migration)
        migrations.validate!
        applied = load.to_h { |entry| {entry.version, entry} }
        pending = [] of Migration

        migrations.each do |migration|
          if entry = applied[migration.version]?
            if entry.name != migration.name
              raise MigrationHistoryMismatchError.new(
                migration.version,
                migration.name,
                entry.name
              )
            end
          else
            pending << migration
          end
        end

        pending
      end

      private def quote(identifier : String) : String
        @dialect.quote_identifier(identifier)
      end

      private def notify(event : StatementCompletionEvent) : Nil
        @observer.try &.call(event)
      rescue
        # Observability must not replace migration or database behavior.
      end
    end
  end
end
