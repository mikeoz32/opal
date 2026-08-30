module LF
  module Data
    module Schema
      abstract class Introspector
        protected getter connection : DB::Connection

        def initialize(@connection : DB::Connection)
        end

        abstract def inspect(
          observer : StatementObserver? = nil,
          ignored_tables : Set(String) = Set(String).new,
        ) : Snapshot

        protected def observe(
          name : String,
          sql : String,
          observer : StatementObserver?,
          & : -> T
        ) : T forall T
          return yield unless observer

          started_at = Time.instant
          statement_error = nil.as(Exception?)
          begin
            yield
          rescue error
            statement_error = error
            raise error
          ensure
            begin
              observer.call(
                StatementCompletionEvent.new(
                  StatementOperation::Schema,
                  name,
                  sql,
                  Time.instant - started_at,
                  nil,
                  statement_error
                )
              )
            rescue
              # Observability must not replace inspection or database behavior.
            end
          end
        end
      end
    end
  end
end
