require "../../data"

module LF
  module Data
    module Dialects
      class PostgreSQL < LF::Data::Dialect
        module StaticSQLPolicy
          IDENTIFIER_OPEN            = %(")
          IDENTIFIER_CLOSE           = %(")
          IDENTIFIER_ESCAPE_FROM     = %(")
          IDENTIFIER_ESCAPE_TO       = %("")
          PLACEHOLDER_STYLE          = :numbered
          PLACEHOLDER_PREFIX         = "$"
          PLACEHOLDER_FIRST_POSITION = 1
          EMPTY_INSERT_STYLE         = :default_values
          GENERATED_KEY_SOURCE       = SQL::GeneratedKeySource::ReturningRow
        end

        STATIC_SQL_POLICY = StaticSQLPolicy
        include SQL::StaticPlanCompiler

        def initialize(@lock_poll_interval : Time::Span = 50.milliseconds)
          if @lock_poll_interval <= Time::Span.zero
            raise ArgumentError.new("PostgreSQL migration lock poll interval must be positive")
          end
        end

        def name : String
          "postgresql"
        end

        def quote_identifier(identifier : String) : String
          if identifier.empty? || identifier.includes?('\0')
            raise ArgumentError.new("Invalid SQL identifier")
          end

          StaticSQLPolicy::IDENTIFIER_OPEN +
            identifier.gsub(
              StaticSQLPolicy::IDENTIFIER_ESCAPE_FROM,
              StaticSQLPolicy::IDENTIFIER_ESCAPE_TO
            ) +
            StaticSQLPolicy::IDENTIFIER_CLOSE
        end

        def placeholder(position : Int32) : String
          raise ArgumentError.new("Placeholder position must be positive") if position <= 0
          "$#{position}"
        end

        def migration_lock(
          connection : DB::Connection,
          namespace : String,
          timeout : Time::Span,
        ) : LF::Data::MigrationLock
          AdvisoryMigrationLock.new(
            connection,
            name,
            namespace,
            timeout,
            @lock_poll_interval
          )
        end

        def supports?(capability : DialectCapability) : Bool
          case capability
          when .returning_row?, .transactional_ddl?, .migration_lock?,
               .add_column?, .rename_column?, .foreign_key_ddl?
            true
          when .last_insert_id?
            false
          else
            false
          end
        end
      end
    end
  end
end

require "./postgresql/advisory_migration_lock"
require "./postgresql/schema_compiler"
require "./postgresql/schema_renderer"
