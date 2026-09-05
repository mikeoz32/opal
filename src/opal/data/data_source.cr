module LF
  module Data
    # Owns a database pool, selected dialect, transaction boundary, and optional
    # statement/transaction listeners.
    #
    # `DataSource.open` owns and closes the `DB::Database` it creates. Passing
    # an existing database to `#new` borrows it by default. Every
    # `EntityManager` is created inside `#transaction` and closes before that
    # block returns; do not cache, inject, or reuse it afterwards.
    class DataSource
      private record TransactionValue(T), value : T

      getter dialect : Dialect
      getter? closed = false
      getter? owns_database : Bool

      @dispatcher : Internal::ListenerDispatcher

      # Opens a database URL and initializes each checked-out connection with
      # the selected dialect. The caller owns the returned source and must call
      # `#close` when it is not application-owned by autoconfiguration.
      def self.open(
        url : URI | String,
        *,
        dialect : Dialect,
        listeners : Enumerable(Listener)? = nil,
      ) : self
        database = DB.open(url)
        begin
          source = new(
            database,
            dialect: dialect,
            owns_database: true,
            listeners: listeners
          )
          source.__lf_setup_connection
          source
        rescue error
          begin
            database.close
          rescue
          end
          raise error
        end
      end

      def initialize(
        @database : DB::Database,
        @dialect : Dialect,
        @owns_database : Bool = false,
        listeners : Enumerable(Listener)? = nil,
      )
        @dispatcher = Internal::ListenerDispatcher.new(listeners)
      end

      # Closes an owned database pool. Calling this method is idempotent.
      # Borrowed databases remain open.
      def close : Nil
        return if closed?

        close_database if owns_database?
        @closed = true
      end

      # Runs one explicit unit of work. Opal flushes pending entity operations
      # before committing and rolls back if the block or flush raises.
      #
      # The yielded manager is valid only inside this block. After a rollback,
      # discard entities obtained from that manager because generated IDs or
      # optimistic-lock versions may have changed in memory before the database
      # transaction was undone.
      def transaction(& : EntityManager -> T) : T forall T
        ensure_open(:transaction)

        __lf_transaction do |manager|
          yield manager
        end
      end

      # Reads the live schema through a dialect that supports schema inspection.
      # This is read-only and is the input to explicit schema-diff and migration
      # source generation; it never synchronizes or mutates the database.
      def inspect_schema(
        ignored_tables : Set(String) = Set(String).new,
      ) : Schema::Snapshot
        ensure_open(:schema_inspection)
        unless @dialect.supports?(DialectCapability::SchemaInspection)
          raise UnsupportedSchemaInspectionError.new(@dialect.name)
        end
        __lf_with_connection do |connection|
          @dialect.schema_introspector(connection).inspect(
            __lf_statement_observer,
            ignored_tables
          ).as(Schema::Snapshot)
        end
      end

      # Framework internal: migration reconciliation needs to distinguish a
      # rollback from a successful commit that failed during manager cleanup.
      def __lf_transaction(
        completion : Proc(TransactionFinalization, Nil)? = nil,
        & : EntityManager -> T
      ) : T forall T
        __lf_with_connection do |connection|
          __lf_transaction_on(connection, completion) do |manager|
            yield manager
          end
        end
      end

      # Framework internal: pins migration planning, execution, and dialect
      # coordination to one checked-out connection.
      def __lf_with_connection(& : DB::Connection -> T) : T forall T
        ensure_open(:migration_session)
        @database.using_connection do |connection|
          @dialect.setup_connection(connection)
          yield connection
        end
      end

      # Framework internal: opens an observed transaction on an already pinned
      # datasource connection.
      def __lf_transaction_on(
        connection : DB::Connection,
        completion : Proc(TransactionFinalization, Nil)? = nil,
        & : EntityManager -> T
      ) : T forall T
        ensure_open(:transaction)
        observed = !@dispatcher.empty?
        started_at = Time.instant if observed
        @dispatcher.transaction_begin(TransactionBeginEvent.new) if observed
        outcome = TransactionOutcome::RolledBack
        finalization = TransactionFinalization::RolledBack

        result = begin
          manager = build_entity_manager(connection, @dialect, @dispatcher)
          primary_error = nil.as(Exception?)

          begin
            rollback_error = nil.as(DB::Rollback?)
            wrapped = connection.transaction do
              begin
                value = yield manager
                manager.flush
                TransactionValue(T).new(value)
              rescue error : DB::Rollback
                rollback_error = error
                raise error
              end
            end

            raise rollback_error.not_nil! if rollback_error
            outcome = TransactionOutcome::Committed
            finalization = TransactionFinalization::Committed
            wrapped.not_nil!.value
          rescue error
            primary_error = error
            finalization = TransactionFinalization::RolledBack
            raise error
          ensure
            begin
              manager.close
            rescue close_error
              finalization = primary_error ? TransactionFinalization::RolledBack : TransactionFinalization::CleanupFailed
              raise close_error unless primary_error
            end
          end
        ensure
          completion.try &.call(finalization)
          if started_at
            @dispatcher.transaction_completion(
              TransactionCompletionEvent.new(outcome, Time.instant - started_at)
            )
          end
        end
        result
      end

      protected def build_entity_manager(
        connection : DB::Connection,
        dialect : Dialect,
        dispatcher : Internal::ListenerDispatcher,
      ) : EntityManager
        EntityManager.new(connection, dialect, dispatcher)
      end

      protected def close_database : Nil
        @database.close
      end

      # Framework internal: migration reconciliation must not emit a second
      # transaction/listener event after a failed migration transaction.
      def __lf_migration_applied?(version : Int64, name : String) : Bool
        ensure_open(:migration_reconciliation)
        __lf_with_connection do |connection|
          __lf_migration_applied?(connection, version, name)
        end
      end

      # Framework internal: reconciliation on the migration session connection.
      def __lf_migration_applied?(
        connection : DB::Connection,
        version : Int64,
        name : String,
      ) : Bool
        observer = __lf_statement_observer
        history = MigrationHistory.new(connection, @dialect, observer)
        entry = history.load.find { |candidate| candidate.version == version }
        if entry
          unless entry.name == name
            raise MigrationHistoryMismatchError.new(version, name, entry.name)
          end
          true
        else
          false
        end
      end

      # Framework internal: validate the first owned connection before open
      # returns. Future connections are initialized on transaction checkout.
      def __lf_setup_connection : Nil
        ensure_open(:connection_setup)
        @database.using_connection do |connection|
          @dialect.setup_connection(connection)
        end
      end

      private def ensure_open(operation : Symbol) : Nil
        raise ClosedDataSourceError.new(operation) if closed?
      end

      private def __lf_statement_observer : StatementObserver?
        return nil if @dispatcher.empty?

        ->(event : StatementCompletionEvent) do
          @dispatcher.statement_completion(event)
          nil
        end
      end
    end
  end
end
