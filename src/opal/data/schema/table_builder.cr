module LF
  module Data
    module Schema
      private struct NoDefault
      end

      class TableBuilder
        getter name : String

        @columns = [] of ColumnDefinition
        @column_names = Set(String).new
        @primary_key : PrimaryKeyDefinition?
        @foreign_keys = [] of ForeignKeyDefinition
        @unique_constraints = [] of UniqueDefinition
        @indexes = [] of IndexDefinition
        @constraint_names = Set(String).new
        @index_names = Set(String).new

        def initialize(@name : String)
          Schema.validate_identifier(name)
        end

        def generated_id(name : String) : Nil
          raise ArgumentError.new("Table #{self.name} already has a primary key") if @primary_key

          add_column(name, ColumnType::Int64, false, NoDefault.new, generated: true)
          primary_key(name)
        end

        def string(
          name : String,
          *,
          null : Bool = true,
          default : String | NoDefault = NoDefault.new,
        ) : Nil
          add_column(name, ColumnType::String, null, default)
        end

        def text(
          name : String,
          *,
          null : Bool = true,
          default : String | NoDefault = NoDefault.new,
        ) : Nil
          add_column(name, ColumnType::Text, null, default)
        end

        def bool(
          name : String,
          *,
          null : Bool = true,
          default : Bool | NoDefault = NoDefault.new,
        ) : Nil
          add_column(name, ColumnType::Bool, null, default)
        end

        def int32(
          name : String,
          *,
          null : Bool = true,
          default : Int32 | NoDefault = NoDefault.new,
        ) : Nil
          add_column(name, ColumnType::Int32, null, default)
        end

        def int64(
          name : String,
          *,
          null : Bool = true,
          default : Int64 | NoDefault = NoDefault.new,
        ) : Nil
          add_column(name, ColumnType::Int64, null, default)
        end

        def float64(
          name : String,
          *,
          null : Bool = true,
          default : Float64 | NoDefault = NoDefault.new,
        ) : Nil
          if default.is_a?(Float64) && !default.finite?
            raise ArgumentError.new("Float64 schema default must be finite")
          end
          add_column(name, ColumnType::Float64, null, default)
        end

        def timestamp(
          name : String,
          *,
          null : Bool = true,
          default : Time | NoDefault = NoDefault.new,
        ) : Nil
          add_column(name, ColumnType::Timestamp, null, default)
        end

        def bytes(
          name : String,
          *,
          null : Bool = true,
          default : Bytes | NoDefault = NoDefault.new,
        ) : Nil
          add_column(name, ColumnType::Bytes, null, default)
        end

        def primary_key(*columns : String, name : String? = nil) : Nil
          raise ArgumentError.new("Table #{self.name} already has a primary key") if @primary_key

          validated = validate_local_columns(columns)
          register_constraint_name(name)
          @primary_key = PrimaryKeyDefinition.new(validated, name)
        end

        def foreign_key(
          local_column : String,
          *,
          references_table : String,
          references_column : String,
          name : String? = nil,
        ) : Nil
          local_columns = validate_local_columns({local_column})
          Schema.validate_identifier(references_table)
          Schema.validate_identifier(references_column)
          register_constraint_name(name)
          definition = ForeignKeyDefinition.new(
            local_columns,
            references_table,
            [references_column],
            name
          )
          if @foreign_keys.any? { |existing| existing == definition }
            raise ArgumentError.new("Duplicate foreign key constraint on #{local_column}")
          end
          @foreign_keys << definition
        end

        def unique(*columns : String, name : String? = nil) : Nil
          validated = validate_local_columns(columns)
          register_constraint_name(name)
          definition = UniqueDefinition.new(validated, name)
          if @unique_constraints.any? { |existing| existing.columns == validated }
            raise ArgumentError.new("Duplicate unique constraint on #{validated.join(", ")}")
          end
          @unique_constraints << definition
        end

        def index(
          name : String,
          *columns : String,
          unique : Bool = false,
        ) : Nil
          Schema.validate_identifier(name)
          unless @index_names.add?(name)
            raise ArgumentError.new("Duplicate index #{name.inspect}")
          end
          validated = validate_local_columns(columns)
          @indexes << IndexDefinition.new(name, validated, unique)
        end

        def build : TableDefinition
          TableDefinition.new(
            name,
            @columns.dup,
            @primary_key,
            @foreign_keys.dup,
            @unique_constraints.dup,
            @indexes.dup
          )
        end

        private def add_column(
          name : String,
          type : ColumnType,
          nullable : Bool,
          default,
          *,
          generated : Bool = false,
        ) : Nil
          Schema.validate_identifier(name)
          unless @column_names.add?(name)
            raise ArgumentError.new("Duplicate column #{name.inspect} on table #{self.name}")
          end

          schema_default = if default.is_a?(NoDefault)
                             nil
                           else
                             DefaultValue.new(default)
                           end
          @columns << ColumnDefinition.new(
            name,
            type,
            nullable,
            schema_default,
            generated
          )
        end

        private def validate_local_columns(columns) : Array(String)
          validated = columns.to_a
          raise ArgumentError.new("Schema constraint must reference at least one column") if validated.empty?

          validated.each do |column|
            Schema.validate_identifier(column)
            unless @column_names.includes?(column)
              raise ArgumentError.new(
                "Schema constraint references missing local column #{column.inspect}"
              )
            end
          end
          validated
        end

        private def register_constraint_name(name : String?) : Nil
          return unless name

          Schema.validate_identifier(name)
          unless @constraint_names.add?(name)
            raise ArgumentError.new("Duplicate constraint #{name.inspect}")
          end
        end
      end
    end
  end
end
