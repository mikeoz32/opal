module LF
  module Data
    module Dialects
      class PostgreSQL
        class SchemaIntrospector < LF::Data::Schema::Introspector
          TABLES_SQL = <<-SQL
            SELECT table_name
            FROM information_schema.tables
            WHERE table_schema = current_schema()
              AND table_type = 'BASE TABLE'
            ORDER BY table_name
            SQL
          COLUMNS_SQL = <<-SQL
            SELECT column_name,
                   data_type,
                   character_maximum_length::bigint,
                   is_nullable,
                   column_default,
                   is_identity
            FROM information_schema.columns
            WHERE table_schema = current_schema()
              AND table_name = $1
            ORDER BY ordinal_position
            SQL
          CONSTRAINTS_SQL = <<-SQL
            SELECT constraint_data.conname,
                   constraint_data.contype::text,
                   local_attribute.attname,
                   referenced_table.relname,
                   referenced_attribute.attname,
                   local_key.position::bigint
            FROM pg_constraint AS constraint_data
            JOIN pg_class AS local_table
              ON local_table.oid = constraint_data.conrelid
            JOIN pg_namespace AS table_namespace
              ON table_namespace.oid = local_table.relnamespace
            LEFT JOIN LATERAL
              unnest(constraint_data.conkey) WITH ORDINALITY
              AS local_key(attnum, position)
              ON TRUE
            LEFT JOIN pg_attribute AS local_attribute
              ON local_attribute.attrelid = local_table.oid
             AND local_attribute.attnum = local_key.attnum
            LEFT JOIN pg_class AS referenced_table
              ON referenced_table.oid = constraint_data.confrelid
            LEFT JOIN LATERAL
              unnest(constraint_data.confkey) WITH ORDINALITY
              AS referenced_key(attnum, position)
              ON referenced_key.position = local_key.position
            LEFT JOIN pg_attribute AS referenced_attribute
              ON referenced_attribute.attrelid = referenced_table.oid
             AND referenced_attribute.attnum = referenced_key.attnum
            WHERE table_namespace.nspname = current_schema()
              AND local_table.relname = $1
              AND constraint_data.contype IN ('p', 'u', 'f')
            ORDER BY constraint_data.conname, local_key.position
            SQL
          INDEXES_SQL = <<-SQL
            SELECT index_table.relname,
                   index_data.indisunique,
                   indexed_attribute.attname,
                   index_key.position::bigint,
                   (
                     index_data.indpred IS NULL
                     AND index_data.indexprs IS NULL
                     AND index_data.indnatts = index_data.indnkeyatts
                   ) AS portable
            FROM pg_index AS index_data
            JOIN pg_class AS source_table
              ON source_table.oid = index_data.indrelid
            JOIN pg_namespace AS table_namespace
              ON table_namespace.oid = source_table.relnamespace
            JOIN pg_class AS index_table
              ON index_table.oid = index_data.indexrelid
            CROSS JOIN LATERAL
              unnest(index_data.indkey) WITH ORDINALITY
              AS index_key(attnum, position)
            LEFT JOIN pg_attribute AS indexed_attribute
              ON indexed_attribute.attrelid = source_table.oid
             AND indexed_attribute.attnum = index_key.attnum
            LEFT JOIN pg_constraint AS constraint_data
              ON constraint_data.conindid = index_data.indexrelid
            WHERE table_namespace.nspname = current_schema()
              AND source_table.relname = $1
              AND constraint_data.oid IS NULL
            ORDER BY index_table.relname, index_key.position
            SQL

          private class ConstraintGroup
            getter name : String
            getter type : String
            getter local_columns = [] of String
            getter referenced_columns = [] of String
            getter referenced_table : String?

            def initialize(
              @name : String,
              @type : String,
              @referenced_table : String?,
            )
            end
          end

          private class IndexGroup
            getter name : String
            getter? unique : Bool
            getter columns = [] of String
            property? portable = true

            def initialize(@name : String, @unique : Bool)
            end
          end

          def inspect(
            observer : LF::Data::StatementObserver? = nil,
            ignored_tables : Set(String) = Set(String).new,
          ) : LF::Data::Schema::Snapshot
            tables = table_names(observer).reject do |table_name|
              ignored_tables.includes?(table_name)
            end.map do |table_name|
              inspect_table(table_name, observer)
            end
            LF::Data::Schema::Snapshot.new(tables)
          end

          private def table_names(
            observer : LF::Data::StatementObserver?,
          ) : Array(String)
            observe("schema.tables", TABLES_SQL, observer) do
              names = [] of String
              connection.query(TABLES_SQL) do |result|
                while result.move_next
                  names << result.read(String)
                end
              end
              names
            end
          end

          private def inspect_table(
            table_name : String,
            observer : LF::Data::StatementObserver?,
          ) : LF::Data::Schema::TableSnapshot
            columns = columns(table_name, observer)
            primary_key, unique_constraints, foreign_keys = constraints(
              table_name,
              observer
            )
            LF::Data::Schema::TableSnapshot.new(
              table_name,
              columns,
              primary_key,
              foreign_keys,
              unique_constraints,
              indexes(table_name, observer)
            )
          end

          private def columns(
            table_name : String,
            observer : LF::Data::StatementObserver?,
          ) : Array(LF::Data::Schema::ColumnSnapshot)
            observe("schema.columns.#{table_name}", COLUMNS_SQL, observer) do
              columns = [] of LF::Data::Schema::ColumnSnapshot
              connection.query(COLUMNS_SQL, table_name) do |result|
                while result.move_next
                  name = result.read(String)
                  database_type = result.read(String)
                  length = result.read(Int64?)
                  type = column_type(database_type, length)
                  nullable = result.read(String) == "YES"
                  default_expression = result.read(String?)
                  generated = result.read(String) == "YES"
                  columns << LF::Data::Schema::ColumnSnapshot.new(
                    name,
                    type,
                    nullable,
                    parse_default(type, default_expression),
                    generated,
                    default_expression
                  )
                end
              end
              columns
            end
          end

          private def constraints(
            table_name : String,
            observer : LF::Data::StatementObserver?,
          ) : Tuple(
            LF::Data::Schema::PrimaryKeyDefinition?,
            Array(LF::Data::Schema::UniqueDefinition),
            Array(LF::Data::Schema::ForeignKeyDefinition),
          )
            observe("schema.constraints.#{table_name}", CONSTRAINTS_SQL, observer) do
              groups = {} of String => ConstraintGroup
              connection.query(CONSTRAINTS_SQL, table_name) do |result|
                while result.move_next
                  name = result.read(String)
                  type = result.read(String)
                  local_column = result.read(String?)
                  referenced_table = result.read(String?)
                  referenced_column = result.read(String?)
                  result.read(Int64?) # order is represented by query ordering
                  group = groups[name]? || begin
                    created = ConstraintGroup.new(name, type, referenced_table)
                    groups[name] = created
                    created
                  end
                  unless group.type == type &&
                         group.referenced_table == referenced_table
                    raise SchemaInspectionError.new(
                      "postgresql",
                      "constraint #{name.inspect} has inconsistent metadata"
                    )
                  end
                  unless local_column
                    raise SchemaInspectionError.new(
                      "postgresql",
                      "constraint #{name.inspect} has no portable local column"
                    )
                  end
                  group.local_columns << local_column
                  if type == "f"
                    unless referenced_column
                      raise SchemaInspectionError.new(
                        "postgresql",
                        "foreign key #{name.inspect} has no referenced column"
                      )
                    end
                    group.referenced_columns << referenced_column
                  end
                end
              end

              primary_key = nil.as(LF::Data::Schema::PrimaryKeyDefinition?)
              unique_constraints = [] of LF::Data::Schema::UniqueDefinition
              foreign_keys = [] of LF::Data::Schema::ForeignKeyDefinition
              groups.values.sort_by(&.name).each do |group|
                case group.type
                when "p"
                  if primary_key
                    raise SchemaInspectionError.new(
                      "postgresql",
                      "table #{table_name.inspect} has multiple primary keys"
                    )
                  end
                  primary_key = LF::Data::Schema::PrimaryKeyDefinition.new(
                    group.local_columns,
                    group.name
                  )
                when "u"
                  unique_constraints << LF::Data::Schema::UniqueDefinition.new(
                    group.local_columns,
                    group.name
                  )
                when "f"
                  referenced_table = group.referenced_table
                  unless referenced_table
                    raise SchemaInspectionError.new(
                      "postgresql",
                      "foreign key #{group.name.inspect} has no referenced table"
                    )
                  end
                  foreign_keys << LF::Data::Schema::ForeignKeyDefinition.new(
                    group.local_columns,
                    referenced_table,
                    group.referenced_columns,
                    group.name
                  )
                end
              end
              {primary_key, unique_constraints, foreign_keys}
            end
          end

          private def indexes(
            table_name : String,
            observer : LF::Data::StatementObserver?,
          ) : Array(LF::Data::Schema::IndexDefinition)
            observe("schema.indexes.#{table_name}", INDEXES_SQL, observer) do
              groups = {} of String => IndexGroup
              connection.query(INDEXES_SQL, table_name) do |result|
                while result.move_next
                  name = result.read(String)
                  unique = result.read(Bool)
                  column = result.read(String?)
                  result.read(Int64) # order is represented by query ordering
                  portable = result.read(Bool)
                  group = groups[name]? || begin
                    created = IndexGroup.new(name, unique)
                    groups[name] = created
                    created
                  end
                  group.portable = false unless portable && column
                  group.columns << column if column
                end
              end
              groups.values.sort_by(&.name).map do |group|
                unless group.portable?
                  raise SchemaInspectionError.new(
                    "postgresql",
                    "index #{group.name.inspect} is outside the portable schema model"
                  )
                end
                LF::Data::Schema::IndexDefinition.new(
                  group.name,
                  group.columns,
                  group.unique?
                )
              end
            end
          end

          private def column_type(
            database_type : String,
            length : Int64?,
          ) : LF::Data::Schema::ColumnType
            case database_type
            when "character varying"
              unless length == 255_i64
                raise SchemaInspectionError.new(
                  "postgresql",
                  "VARCHAR length #{length.inspect} is outside the portable schema model"
                )
              end
              LF::Data::Schema::ColumnType::String
            when "text"
              LF::Data::Schema::ColumnType::Text
            when "boolean"
              LF::Data::Schema::ColumnType::Bool
            when "integer"
              LF::Data::Schema::ColumnType::Int32
            when "bigint"
              LF::Data::Schema::ColumnType::Int64
            when "double precision"
              LF::Data::Schema::ColumnType::Float64
            when "timestamp with time zone"
              LF::Data::Schema::ColumnType::Timestamp
            when "bytea"
              LF::Data::Schema::ColumnType::Bytes
            else
              raise SchemaInspectionError.new(
                "postgresql",
                "column type #{database_type.inspect} is outside the portable schema model"
              )
            end
          end

          private def parse_default(
            type : LF::Data::Schema::ColumnType,
            expression : String?,
          ) : LF::Data::Schema::DefaultValue?
            return nil unless raw = expression
            value = raw.strip
            case type
            when .string?, .text?
              parsed = quoted_literal(value)
              parsed ? LF::Data::Schema::DefaultValue.new(parsed) : nil
            when .bool?
              case value.downcase
              when "true"
                LF::Data::Schema::DefaultValue.new(true)
              when "false"
                LF::Data::Schema::DefaultValue.new(false)
              end
            when .int32?, .int64?
              if /\A[-+]?\d+\z/.matches?(value)
                LF::Data::Schema::DefaultValue.new(value.to_i64)
              end
            when .float64?
              if /\A[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?\z/.matches?(value)
                LF::Data::Schema::DefaultValue.new(value.to_f64)
              end
            when .timestamp?
              if timestamp = quoted_literal(value)
                begin
                  normalized = timestamp.sub(" ", "T")
                  if /[+-]\d{2}\z/.matches?(normalized)
                    normalized += ":00"
                  end
                  LF::Data::Schema::DefaultValue.new(
                    Time::Format::RFC_3339.parse(normalized)
                  )
                rescue Time::Format::Error
                  nil
                end
              end
            when .bytes?
              if match = /\Adecode\('([0-9a-fA-F]*)'(?:::text)?,\s*'hex'(?:::text)?\)\z/.match(value)
                LF::Data::Schema::DefaultValue.new(match[1].hexbytes)
              end
            end
          end

          private def quoted_literal(expression : String) : String?
            match = /\A'((?:''|[^'])*)'/.match(expression)
            match.try { |value| value[1].gsub("''", "'") }
          end
        end
      end
    end
  end
end
