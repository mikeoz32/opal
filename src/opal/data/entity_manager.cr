module LF
  module Data
    class EntityManager
      getter? closed = false

      @failure : Exception?

      def initialize(
        @connection : DB::Connection,
        @dialect : Dialect,
        @dispatcher : Internal::ListenerDispatcher,
      )
      end

      def flush : Nil
        ensure_available(:flush)

        begin
          do_flush
        rescue error
          @failure = error
          raise error
        end
      end

      def close : Nil
        return if closed?

        @closed = true
        do_close
      end

      protected getter connection : DB::Connection
      protected getter dialect : Dialect

      protected def dispatch_statement(event : StatementCompletionEvent) : Nil
        @dispatcher.statement_completion(event)
      end

      protected def do_flush : Nil
      end

      protected def do_close : Nil
      end

      private def ensure_available(operation : Symbol) : Nil
        if failure = @failure
          raise FailedEntityManagerError.new(operation, failure)
        end
        raise ClosedEntityManagerError.new(operation) if closed?
      end
    end
  end
end
