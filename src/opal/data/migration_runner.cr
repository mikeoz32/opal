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

        pending.each do |migration|
          @source.transaction do |manager|
            connection = manager.connection
            observer = manager.__lf_statement_observer
            history = MigrationHistory.new(connection, @source.dialect, observer)
            schema = SchemaEditor.new(
              @source.dialect.schema_renderer(connection),
              observer
            )
            migration.up(schema)
            history.record(migration)
          end
        end
      end
    end
  end
end
