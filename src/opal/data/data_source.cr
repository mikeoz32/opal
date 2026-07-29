module LF
  module Data
    class DataSource
      private record TransactionValue(T), value : T

      getter dialect : Dialect
      getter? closed = false
      getter? owns_database : Bool

      @dispatcher : Internal::ListenerDispatcher

      def self.open(
        url : URI | String,
        *,
        dialect : Dialect,
        listeners : Enumerable(Listener)? = nil,
      ) : self
        new(
          DB.open(url),
          dialect: dialect,
          owns_database: true,
          listeners: listeners
        )
      end

      def initialize(
        @database : DB::Database,
        @dialect : Dialect,
        @owns_database : Bool = false,
        listeners : Enumerable(Listener)? = nil,
      )
        @dispatcher = Internal::ListenerDispatcher.new(listeners)
      end

      def close : Nil
        return if closed?

        @closed = true
        @database.close if owns_database?
      end

      def transaction(& : EntityManager -> T) : T forall T
        ensure_open(:transaction)

        observed = !@dispatcher.empty?
        started_at = Time.instant if observed
        @dispatcher.transaction_begin(TransactionBeginEvent.new) if observed
        outcome = TransactionOutcome::RolledBack

        begin
          result = @database.using_connection do |connection|
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
              wrapped.not_nil!.value
            rescue error
              primary_error = error
              raise error
            ensure
              begin
                manager.close
              rescue close_error
                raise close_error unless primary_error
              end
            end
          end

          result
        ensure
          if started_at
            @dispatcher.transaction_completion(
              TransactionCompletionEvent.new(outcome, Time.instant - started_at)
            )
          end
        end
      end

      protected def build_entity_manager(
        connection : DB::Connection,
        dialect : Dialect,
        dispatcher : Internal::ListenerDispatcher,
      ) : EntityManager
        EntityManager.new(connection, dialect, dispatcher)
      end

      private def ensure_open(operation : Symbol) : Nil
        raise ClosedDataSourceError.new(operation) if closed?
      end
    end
  end
end
