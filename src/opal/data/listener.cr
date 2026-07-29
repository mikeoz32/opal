module LF
  module Data
    enum TransactionOutcome
      Committed
      RolledBack
    end

    enum StatementOperation
      Select
      Insert
      Update
      Delete
      Schema
      Other
    end

    record TransactionBeginEvent

    record TransactionCompletionEvent,
      outcome : TransactionOutcome,
      elapsed : Time::Span

    record StatementCompletionEvent,
      operation : StatementOperation,
      entity_name : String?,
      sql : String,
      elapsed : Time::Span,
      rows_affected : Int64?,
      error : Exception?

    module Listener
      def on_transaction_begin(event : TransactionBeginEvent) : Nil
      end

      def on_transaction_completion(event : TransactionCompletionEvent) : Nil
      end

      def on_statement_completion(event : StatementCompletionEvent) : Nil
      end
    end

    module Internal
      # Event fan-out shared by DataSource and transaction-local managers.
      class ListenerDispatcher
        def initialize(listeners : Enumerable(Listener)? = nil)
          @listeners = [] of Listener
          listeners.try &.each { |listener| @listeners << listener }
        end

        def empty? : Bool
          @listeners.empty?
        end

        def transaction_begin(event : TransactionBeginEvent) : Nil
          dispatch { |listener| listener.on_transaction_begin(event) }
        end

        def transaction_completion(event : TransactionCompletionEvent) : Nil
          dispatch { |listener| listener.on_transaction_completion(event) }
        end

        def statement_completion(event : StatementCompletionEvent) : Nil
          dispatch { |listener| listener.on_statement_completion(event) }
        end

        private def dispatch(& : Listener ->) : Nil
          @listeners.each do |listener|
            begin
              yield listener
            rescue
              # Observability must never replace an application or database error.
            end
          end
        end
      end
    end
  end
end
