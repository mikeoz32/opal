module LF
  module Data
    module Dialects
      class SQLite
        class SchemaIntrospector < LF::Data::Schema::Introspector
          TABLES_SQL = <<-SQL
            SELECT name, sql
            FROM sqlite_schema
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            ORDER BY name
            SQL
          COLUMNS_SQL = <<-SQL
            SELECT name, type, "notnull", dflt_value, pk
            FROM pragma_table_xinfo(?)
            WHERE hidden = 0
            ORDER BY cid
            SQL
          INDEXES_SQL = <<-SQL
            SELECT name, "unique", origin, partial
            FROM pragma_index_list(?)
            ORDER BY name
            SQL
          INDEX_COLUMNS_SQL = <<-SQL
            SELECT name
            FROM pragma_index_info(?)
            ORDER BY seqno
            SQL
          FOREIGN_KEYS_SQL = <<-SQL
            SELECT id, seq, "table", "from", "to"
            FROM pragma_foreign_key_list(?)
            ORDER BY id, seq
            SQL

          def inspect(
            observer : LF::Data::StatementObserver? = nil,
            ignored_tables : Set(String) = Set(String).new,
          ) : LF::Data::Schema::Snapshot
            tables = [] of LF::Data::Schema::TableSnapshot
            table_rows(observer).each do |name, create_sql|
              next if ignored_tables.includes?(name)
              tables << inspect_table(name, create_sql, observer)
            end
            LF::Data::Schema::Snapshot.new(tables)
          end

          private def table_rows(
            observer : LF::Data::StatementObserver?,
          ) : Array(Tuple(String, String?))
            observe("schema.tables", TABLES_SQL, observer) do
              rows = [] of Tuple(String, String?)
              connection.query(TABLES_SQL) do |result|
                while result.move_next
                  rows << {result.read(String), result.read(String?)}
                end
              end
              rows
            end
          end

          private def inspect_table(
            name : String,
            create_sql : String?,
            observer : LF::Data::StatementObserver?,
          ) : LF::Data::Schema::TableSnapshot
            columns, primary_key = columns(name, create_sql, observer)
            foreign_keys = foreign_keys(name, observer)
            unique_constraints, indexes = indexes(name, observer)
            LF::Data::Schema::TableSnapshot.new(
              name,
              columns,
              primary_key,
              foreign_keys,
              unique_constraints,
              indexes
            )
          end

          private def columns(
            table_name : String,
            create_sql : String?,
            observer : LF::Data::StatementObserver?,
          ) : Tuple(
            Array(LF::Data::Schema::ColumnSnapshot),
            LF::Data::Schema::PrimaryKeyDefinition?,
          )
            observe("schema.columns.#{table_name}", COLUMNS_SQL, observer) do
              columns = [] of LF::Data::Schema::ColumnSnapshot
              primary_columns = [] of Tuple(Int64, String)
              autoincrement = create_sql.try(&.upcase.includes?("AUTOINCREMENT")) || false
              connection.query(COLUMNS_SQL, table_name) do |result|
                while result.move_next
                  name = result.read(String)
                  declared_type = result.read(String)
                  not_null = result.read(Int64)
                  default_expression = result.read(String?)
                  primary_position = result.read(Int64)
                  type = column_type(declared_type)
                  primary = primary_position > 0
                  primary_columns << {primary_position, name} if primary
                  columns << LF::Data::Schema::ColumnSnapshot.new(
                    name,
                    type,
                    !(not_null == 1 || primary),
                    parse_default(default_expression),
                    autoincrement && primary && type.int64?,
                    default_expression
                  )
                end
              end
              primary_key = if primary_columns.empty?
                              nil
                            else
                              LF::Data::Schema::PrimaryKeyDefinition.new(
                                primary_columns.sort_by(&.[0]).map(&.[1]),
                                nil
                              )
                            end
              {columns, primary_key}
            end
          end

          private def indexes(
            table_name : String,
            observer : LF::Data::StatementObserver?,
          ) : Tuple(
            Array(LF::Data::Schema::UniqueDefinition),
            Array(LF::Data::Schema::IndexDefinition),
          )
            observe("schema.indexes.#{table_name}", INDEXES_SQL, observer) do
              unique_constraints = [] of LF::Data::Schema::UniqueDefinition
              indexes = [] of LF::Data::Schema::IndexDefinition
              connection.query(INDEXES_SQL, table_name) do |result|
                while result.move_next
                  name = result.read(String)
                  unique = result.read(Int64) == 1
                  origin = result.read(String)
                  partial = result.read(Int64) == 1
                  next if origin == "pk"
                  if partial
                    raise SchemaInspectionError.new(
                      "sqlite",
                      "partial index #{name.inspect} is outside the portable schema model"
                    )
                  end
                  columns = index_columns(name, observer)
                  if origin == "u"
                    unique_constraints << LF::Data::Schema::UniqueDefinition.new(
                      columns,
                      nil
                    )
                  else
                    indexes << LF::Data::Schema::IndexDefinition.new(
                      name,
                      columns,
                      unique
                    )
                  end
                end
              end
              {
                unique_constraints.sort_by { |unique| unique.columns.join("\0") },
                indexes.sort_by(&.name),
              }
            end
          end

          private def index_columns(
            index_name : String,
            observer : LF::Data::StatementObserver?,
          ) : Array(String)
            observe("schema.index_columns.#{index_name}", INDEX_COLUMNS_SQL, observer) do
              columns = [] of String
              connection.query(INDEX_COLUMNS_SQL, index_name) do |result|
                while result.move_next
                  column = result.read(String?)
                  unless column
                    raise SchemaInspectionError.new(
                      "sqlite",
                      "expression index #{index_name.inspect} is outside the portable schema model"
                    )
                  end
                  columns << column
                end
              end
              columns
            end
          end

          private def foreign_keys(
            table_name : String,
            observer : LF::Data::StatementObserver?,
          ) : Array(LF::Data::Schema::ForeignKeyDefinition)
            observe("schema.foreign_keys.#{table_name}", FOREIGN_KEYS_SQL, observer) do
              groups = {} of Int64 => Tuple(Array(String), String, Array(String))
              connection.query(FOREIGN_KEYS_SQL, table_name) do |result|
                while result.move_next
                  id = result.read(Int64)
                  result.read(Int64) # sequence is represented by query order
                  referenced_table = result.read(String)
                  local_column = result.read(String)
                  referenced_column = result.read(String?)
                  unless referenced_column
                    raise SchemaInspectionError.new(
                      "sqlite",
                      "foreign key on #{table_name.inspect} omits its referenced column"
                    )
                  end
                  group = groups[id]? || begin
                    created = {[] of String, referenced_table, [] of String}
                    groups[id] = created
                    created
                  end
                  if group[1] != referenced_table
                    raise SchemaInspectionError.new(
                      "sqlite",
                      "foreign key #{id} on #{table_name.inspect} has inconsistent targets"
                    )
                  end
                  group[0] << local_column
                  group[2] << referenced_column
                end
              end
              groups.keys.sort.map do |id|
                local_columns, referenced_table, referenced_columns = groups[id]
                LF::Data::Schema::ForeignKeyDefinition.new(
                  local_columns,
                  referenced_table,
                  referenced_columns,
                  nil
                )
              end
            end
          end

          private def column_type(declared : String) : LF::Data::Schema::ColumnType
            normalized = declared.upcase
            case
            when normalized.includes?("CHAR") || normalized.includes?("VARCHAR")
              LF::Data::Schema::ColumnType::String
            when normalized.includes?("TEXT") || normalized.includes?("CLOB")
              LF::Data::Schema::ColumnType::Text
            when normalized.includes?("INT")
              LF::Data::Schema::ColumnType::Int64
            when normalized.includes?("REAL") || normalized.includes?("FLOA") ||
              normalized.includes?("DOUB")
              LF::Data::Schema::ColumnType::Float64
            when normalized.includes?("BLOB") || normalized.empty?
              LF::Data::Schema::ColumnType::Bytes
            else
              raise SchemaInspectionError.new(
                "sqlite",
                "column type #{declared.inspect} is outside the portable schema model"
              )
            end
          end

          private def parse_default(
            expression : String?,
          ) : LF::Data::Schema::DefaultValue?
            return nil unless raw = expression
            value = raw.strip
            if match = /\AX'([0-9a-fA-F]*)'\z/.match(value)
              return LF::Data::Schema::DefaultValue.new(match[1].hexbytes)
            end
            if value.starts_with?("'") && value.ends_with?("'") && value.size >= 2
              return LF::Data::Schema::DefaultValue.new(
                value[1...-1].gsub("''", "'")
              )
            end
            case value.upcase
            when "TRUE"
              LF::Data::Schema::DefaultValue.new(true)
            when "FALSE"
              LF::Data::Schema::DefaultValue.new(false)
            else
              if /\A[-+]?\d+\z/.matches?(value)
                LF::Data::Schema::DefaultValue.new(value.to_i64)
              elsif /\A[-+]?(?:\d+\.\d*|\d*\.\d+)(?:[eE][-+]?\d+)?\z/.matches?(value)
                LF::Data::Schema::DefaultValue.new(value.to_f64)
              else
                nil
              end
            end
          end
        end
      end
    end
  end
end
