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
          begin
            @source.transaction do |manager|
              connection = manager.connection
              observer = manager.__lf_statement_observer
              history = MigrationHistory.new(connection, @source.dialect, observer)
              schema = SchemaEditor.new(
                @source.dialect.schema_renderer(connection),
                observer
              )
              planned.migration.up(schema)
              history.record(planned)
            end
          rescue error
            raise error unless @source.__lf_migration_applied?(planned.version, planned.name)
          end
        end
      end
    end
  end
end
