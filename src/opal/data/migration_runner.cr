module LF
  module Data
    class MigrationRunner
      DEFAULT_LOCK_NAMESPACE = "opal"
      DEFAULT_LOCK_TIMEOUT   = 30.seconds

      def initialize(
        @source : DataSource,
        @lock_namespace : String = DEFAULT_LOCK_NAMESPACE,
        @lock_timeout : Time::Span = DEFAULT_LOCK_TIMEOUT,
      )
        validate_lock_configuration!
      end

      def run(migrations : MigrationSet) : Nil
        migrations.validate!
        ensure_capability!(DialectCapability::TransactionalDDL)
        ensure_capability!(DialectCapability::MigrationLock)

        @source.__lf_with_connection do |connection|
          lock = @source.dialect.migration_lock(
            connection,
            @lock_namespace,
            @lock_timeout
          )
          with_lock(lock) do
            run_locked(connection, migrations)
          end
        end
      end

      private def run_locked(
        connection : DB::Connection,
        migrations : MigrationSet,
      ) : Nil
        pending = @source.__lf_transaction_on(connection) do |manager|
          history = MigrationHistory.new(
            manager.connection,
            @source.dialect,
            manager.__lf_statement_observer
          )
          history.ensure_table
          history.pending(migrations)
        end

        return if pending.empty?

        pending.each do |planned|
          finalization = TransactionFinalization::RolledBack
          history_record_failed = false
          begin
            @source.__lf_transaction_on(connection, ->(value : TransactionFinalization) { finalization = value; nil }) do |manager|
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
               @source.__lf_migration_applied?(
                 connection,
                 planned.version,
                 planned.name
               )
              next
            end
            raise error
          end
        end
      end

      def __lf_history_record_conflict?(error : Exception) : Bool
        @source.dialect.migration_history_record_conflict?(
          error,
          MigrationHistory::TABLE_NAME,
          "version"
        )
      end

      private def with_lock(lock : MigrationLock, & : ->) : Nil
        primary_error = nil.as(Exception?)
        begin
          lock.acquire
          yield
        rescue error
          primary_error = error
        ensure
          begin
            lock.release
          rescue cleanup_error
            if primary = primary_error
              raise MigrationLockCleanupError.new(primary, cleanup_error)
            end
            raise cleanup_error
          end
        end

        raise primary if primary = primary_error
      end

      private def ensure_capability!(capability : DialectCapability) : Nil
        return if @source.dialect.supports?(capability)

        raise UnsupportedMigrationCapabilityError.new(
          @source.dialect.name,
          capability
        )
      end

      private def validate_lock_configuration! : Nil
        if @lock_namespace.empty? || @lock_namespace.includes?('\0')
          raise MigrationLockConfigurationError.new(
            @lock_namespace,
            @lock_timeout,
            "namespace must not be empty or contain NUL"
          )
        end
        if @lock_timeout < Time::Span.zero
          raise MigrationLockConfigurationError.new(
            @lock_namespace,
            @lock_timeout,
            "timeout must not be negative"
          )
        end
      end
    end
  end
end
