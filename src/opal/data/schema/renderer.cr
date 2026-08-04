module LF
  module Data
    abstract class SchemaRenderer
      alias StatementObserver = Proc(StatementCompletionEvent, Nil)

      getter connection : DB::Connection

      def initialize(@connection : DB::Connection)
      end

      abstract def execute(
        operation : Schema::Operation,
        observer : StatementObserver? = nil,
      ) : Nil
    end
  end
end
