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

        def offset_without_limit(placeholder : String) : String
          "LIMIT -1 OFFSET #{placeholder}"
        end

        def supports?(capability : DialectCapability) : Bool
          case capability
          when .last_insert_id?, .transactional_ddl?, .add_column?, .rename_column?, .foreign_key_ddl?
            true
          when .returning_row?
            false
          else
            false
          end
        end
      end
    end
  end
end
