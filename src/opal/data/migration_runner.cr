module LF
  module Data
    class MigrationRunner
      def initialize(@source : DataSource)
      end

      def run(migrations : MigrationSet) : Nil
        migrations.validate!
        pending = @source.transaction do |manager|
          history = MigrationHistory.new(
            manager.connection,
            @source.dialect,
            manager.__lf_statement_observer
          )
          history.ensure_table
          history.pending(migrations)
        end

        return if pending.empty?

        unless @source.dialect.supports?(DialectCapability::TransactionalDDL)
          raise UnsupportedMigrationCapabilityError.new(
            @source.dialect.name,
            DialectCapability::TransactionalDDL
          )
        end

        pending.each do |planned|
          finalization = TransactionFinalization::RolledBack
          history_record_failed = false
          begin
            @source.__lf_transaction(->(value : TransactionFinalization) { finalization = value; nil }) do |manager|
              connection = manager.connection
              observer = manager.__lf_statement_observer
              history = MigrationHistory.new(connection, @source.dialect, observer)
              schema = SchemaEditor.new(
                @source.dialect.schema_renderer(connection),
                observer
              )
              planned.migration.up(schema)
              begin
                history.record(planned)
              rescue error
                history_record_failed = true
                raise error
              end
            end
          rescue error
              if history_record_failed &&
               finalization == TransactionFinalization::RolledBack &&
               __lf_history_record_conflict?(error) &&
               @source.__lf_migration_applied?(planned.version, planned.name)
              next
            end
            raise error
          end
        end
      end

      def __lf_history_record_conflict?(error : Exception) : Bool
        return false unless @source.dialect.name == "sqlite"
        return false unless error.class.name == "SQLite3::Exception"

        message = error.message || error.to_s
        message.includes?("UNIQUE constraint failed: #{MigrationHistory::TABLE_NAME}.version") ||
          message.includes?("PRIMARY KEY")
      end
    end
  end
end
