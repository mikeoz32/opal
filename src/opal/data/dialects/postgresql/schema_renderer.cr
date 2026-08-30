module LF
  module Data
    module Dialects
      class PostgreSQL
        class SchemaRenderer < LF::Data::SchemaRenderer
          def initialize(connection : DB::Connection, dialect : PostgreSQL)
            super(connection)
            @compiler = SchemaCompiler.new(dialect)
          end

          def execute(
            operation : LF::Data::Schema::Operation,
            observer : LF::Data::StatementObserver? = nil,
          ) : Nil
            @compiler.compile(operation).each do |statement|
              execute_statement(statement, observer)
            end
          end

          private def execute_statement(
            statement : SchemaCompiler::Statement,
            observer : LF::Data::StatementObserver?,
          ) : Nil
            unless observer
              connection.exec(statement.sql)
              return
            end

            started_at = Time.instant
            rows = nil.as(Int64?)
            statement_error = nil.as(Exception?)
            begin
              result = connection.exec(statement.sql)
              rows = result.rows_affected
            rescue error
              statement_error = error
              raise error
            ensure
              begin
                observer.call(
                  StatementCompletionEvent.new(
                    StatementOperation::Schema,
                    statement.name,
                    statement.sql,
                    Time.instant - started_at,
                    rows,
                    statement_error
                  )
                )
              rescue
                # Observability must not replace schema or database behavior.
              end
            end
          end
        end

        def schema_renderer(connection : DB::Connection) : LF::Data::SchemaRenderer
          SchemaRenderer.new(connection, self)
        end
      end
    end
  end
end
