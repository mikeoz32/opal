require "../../data"

module LF
  module Data
    module Dialects
      class SQLite < LF::Data::Dialect
        module StaticSQLPolicy
          IDENTIFIER_OPEN        = %(")
          IDENTIFIER_CLOSE       = %(")
          IDENTIFIER_ESCAPE_FROM = %(")
          IDENTIFIER_ESCAPE_TO   = %("")
          PLACEHOLDER_STYLE      = :anonymous
          PLACEHOLDER_TOKEN      = "?"
          EMPTY_INSERT_STYLE     = :default_values
          GENERATED_KEY_SOURCE   = SQL::GeneratedKeySource::LastInsertId
          OFFSET_ONLY_PREFIX     = "LIMIT -1 OFFSET "
        end

        STATIC_SQL_POLICY = StaticSQLPolicy
        include SQL::StaticPlanCompiler

        def name : String
          "sqlite"
        end

        def quote_identifier(identifier : String) : String
          raise ArgumentError.new("Invalid SQL identifier") if identifier.empty? || identifier.includes?('\0')

          StaticSQLPolicy::IDENTIFIER_OPEN +
            identifier.gsub(
              StaticSQLPolicy::IDENTIFIER_ESCAPE_FROM,
              StaticSQLPolicy::IDENTIFIER_ESCAPE_TO
            ) +
            StaticSQLPolicy::IDENTIFIER_CLOSE
        end

        def placeholder(position : Int32) : String
          StaticSQLPolicy::PLACEHOLDER_TOKEN
        end

        def setup_connection(connection : DB::Connection) : Nil
          connection.exec("PRAGMA foreign_keys = ON")
          value = connection.scalar("PRAGMA foreign_keys").as(Int64)
          raise ForeignKeySetupError.new(name, value) unless value == 1_i64
        end

        def offset_without_limit(placeholder : String) : String
          "LIMIT -1 OFFSET #{placeholder}"
        end

        def schema_type_matches?(
          desired : LF::Data::Schema::ColumnType,
          actual : LF::Data::Schema::ColumnType,
        ) : Bool
          return true if integer_storage_type?(desired) && integer_storage_type?(actual)
          return true if desired.timestamp? && actual.text?

          desired == actual
        end

        def schema_default_matches?(
          desired : LF::Data::Schema::DefaultValue?,
          actual : LF::Data::Schema::ColumnSnapshot,
        ) : Bool
          return !actual.has_default? unless desired
          return false unless inspected = actual.default

          case value = desired.value
          when Bool
            case stored = inspected.value
            when Bool
              value == stored
            when Int32, Int64
              (value ? 1_i64 : 0_i64) == stored.to_i64
            else
              false
            end
          when Time
            case stored = inspected.value
            when Time
              value == stored
            when String
              begin
                value == Time::Format::RFC_3339.parse(stored)
              rescue Time::Format::Error
                false
              end
            else
              false
            end
          else
            super
          end
        end

        def migration_history_record_conflict?(
          error : Exception,
          table : String,
          column : String,
        ) : Bool
          return false unless error.class.name == "SQLite3::Exception"

          message = error.message || error.to_s
          message.includes?("UNIQUE constraint failed: #{table}.#{column}")
        end

        def migration_lock(
          connection : DB::Connection,
          namespace : String,
          timeout : Time::Span,
        ) : LF::Data::MigrationLock
          TransactionalHistoryMigrationLock.new
        end

        def schema_introspector(
          connection : DB::Connection,
        ) : LF::Data::Schema::Introspector
          SchemaIntrospector.new(connection)
        end

        def supports?(capability : DialectCapability) : Bool
          case capability
          when .last_insert_id?, .transactional_ddl?, .migration_lock?,
               .schema_inspection?, .add_column?, .rename_column?,
               .foreign_key_ddl?
            true
          when .returning_row?
            false
          else
            false
          end
        end

        private def integer_storage_type?(
          type : LF::Data::Schema::ColumnType,
        ) : Bool
          type.bool? || type.int32? || type.int64?
        end
      end
    end
  end
end

require "./sqlite/schema_renderer"
require "./sqlite/schema_introspector"
