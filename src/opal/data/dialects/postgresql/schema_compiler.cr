module LF
  module Data
    module Dialects
      class PostgreSQL
        class SchemaCompiler
          record Statement, name : String, sql : String

          def initialize(@dialect : PostgreSQL)
          end

          def compile(
            operation : LF::Data::Schema::Operation,
          ) : Array(Statement)
            case operation
            when LF::Data::Schema::CreateTable
              create_table_statements(operation.table, operation.if_not_exists)
            when LF::Data::Schema::DropTable
              [Statement.new(
                operation.table_name,
                "DROP TABLE #{quote(operation.table_name)}"
              )]
            when LF::Data::Schema::RenameTable
              [Statement.new(
                operation.to,
                "ALTER TABLE #{quote(operation.from)} RENAME TO #{quote(operation.to)}"
              )]
            when LF::Data::Schema::AddColumn
              if operation.column.generated?
                raise UnsupportedSchemaOperationError.new(
                  @dialect.name,
                  "generated ADD COLUMN"
                )
              end
              [Statement.new(
                operation.table_name,
                "ALTER TABLE #{quote(operation.table_name)} ADD COLUMN " \
                "#{column_sql(operation.column)}"
              )]
            when LF::Data::Schema::RenameColumn
              [Statement.new(
                operation.table_name,
                "ALTER TABLE #{quote(operation.table_name)} " \
                "RENAME COLUMN #{quote(operation.from)} TO #{quote(operation.to)}"
              )]
            when LF::Data::Schema::CreateIndex
              [create_index_statement(operation.table_name, operation.index)]
            when LF::Data::Schema::DropIndex
              [Statement.new(
                operation.name,
                "DROP INDEX #{quote(operation.name)}"
              )]
            when LF::Data::Schema::RawSQL
              [Statement.new(operation.name, operation.sql)]
            else
              raise UnsupportedSchemaOperationError.new(
                @dialect.name,
                operation.class.to_s
              )
            end
          end

          private def create_table_statements(
            table : LF::Data::Schema::TableDefinition,
            if_not_exists : Bool,
          ) : Array(Statement)
            generated = table.columns.select(&.generated?)
            if generated.size > 1
              raise UnsupportedSchemaOperationError.new(
                @dialect.name,
                "multiple generated columns"
              )
            end

            generated_column = generated.first?
            if column = generated_column
              primary_key = table.primary_key
              unless column.type.int64? &&
                     primary_key &&
                     primary_key.columns == [column.name]
                raise UnsupportedSchemaOperationError.new(
                  @dialect.name,
                  "generated column without a single Int64 primary key"
                )
              end
            end

            definitions = table.columns.map do |column|
              column_sql(column, inline_generated_key: column == generated_column)
            end
            if primary_key = table.primary_key
              unless generated_column
                definitions << constraint_prefix(primary_key.name) +
                               "PRIMARY KEY (#{quoted_list(primary_key.columns)})"
              end
            end
            table.unique_constraints.each do |unique|
              definitions << constraint_prefix(unique.name) +
                             "UNIQUE (#{quoted_list(unique.columns)})"
            end
            table.foreign_keys.each do |foreign_key|
              definitions << constraint_prefix(foreign_key.name) +
                             "FOREIGN KEY (#{quoted_list(foreign_key.local_columns)}) " \
                             "REFERENCES #{quote(foreign_key.referenced_table)} " \
                             "(#{quoted_list(foreign_key.referenced_columns)})"
            end

            statements = [Statement.new(
              table.name,
              "CREATE TABLE #{"IF NOT EXISTS " if if_not_exists}" \
              "#{quote(table.name)} (#{definitions.join(", ")})"
            )]
            table.indexes.each do |index|
              statements << create_index_statement(
                table.name,
                index,
                if_not_exists
              )
            end
            statements
          end

          private def create_index_statement(
            table_name : String,
            index : LF::Data::Schema::IndexDefinition,
            if_not_exists : Bool = false,
          ) : Statement
            unique = index.unique? ? "UNIQUE " : ""
            existence = if_not_exists ? "IF NOT EXISTS " : ""
            Statement.new(
              index.name,
              "CREATE #{unique}INDEX #{existence}#{quote(index.name)} " \
              "ON #{quote(table_name)} (#{quoted_list(index.columns)})"
            )
          end

          private def column_sql(
            column : LF::Data::Schema::ColumnDefinition,
            *,
            inline_generated_key : Bool = false,
          ) : String
            if inline_generated_key
              return "#{quote(column.name)} BIGINT " \
                     "GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY"
            end

            String.build do |sql|
              sql << quote(column.name) << ' ' << column_type(column.type)
              sql << " NOT NULL" unless column.nullable?
              if default = column.default
                sql << " DEFAULT " << literal(default.value)
              end
            end
          end

          private def column_type(type : LF::Data::Schema::ColumnType) : String
            case type
            when .string?
              "VARCHAR(255)"
            when .text?
              "TEXT"
            when .bool?
              "BOOLEAN"
            when .int32?
              "INTEGER"
            when .int64?
              "BIGINT"
            when .float64?
              "DOUBLE PRECISION"
            when .timestamp?
              "TIMESTAMPTZ"
            when .bytes?
              "BYTEA"
            else
              raise UnsupportedSchemaOperationError.new(
                @dialect.name,
                "column type #{type}"
              )
            end
          end

          private def literal(value : LF::Data::Schema::Literal) : String
            case value
            when String
              "'#{value.gsub("'", "''")}'"
            when Bool
              value ? "TRUE" : "FALSE"
            when Int32, Int64, Float64
              value.to_s
            when Time
              "'#{value.to_utc.to_rfc3339}'"
            when Bytes
              "decode('#{value.hexstring}', 'hex')"
            else
              raise UnsupportedSchemaOperationError.new(
                @dialect.name,
                "literal #{value.class}"
              )
            end
          end

          private def constraint_prefix(name : String?) : String
            name ? "CONSTRAINT #{quote(name)} " : ""
          end

          private def quoted_list(identifiers : Array(String)) : String
            identifiers.map { |identifier| quote(identifier) }.join(", ")
          end

          private def quote(identifier : String) : String
            @dialect.quote_identifier(identifier)
          end
        end
      end
    end
  end
end
