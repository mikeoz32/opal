module LF
  module Data
    module Schema
      alias Literal = String | Bool | Int32 | Int64 | Float64 | Time | Bytes

      enum ColumnType
        String
        Text
        Bool
        Int32
        Int64
        Float64
        Timestamp
        Bytes
      end

      record DefaultValue, value : Literal

      record ColumnDefinition,
        name : String,
        type : ColumnType,
        nullable : Bool,
        default : DefaultValue?,
        generated : Bool do
        def nullable? : Bool
          nullable
        end

        def generated? : Bool
          generated
        end
      end

      record PrimaryKeyDefinition,
        columns : Array(String),
        name : String?

      record ForeignKeyDefinition,
        local_columns : Array(String),
        referenced_table : String,
        referenced_columns : Array(String),
        name : String?

      record UniqueDefinition,
        columns : Array(String),
        name : String?

      record TableDefinition,
        name : String,
        columns : Array(ColumnDefinition),
        primary_key : PrimaryKeyDefinition?,
        foreign_keys : Array(ForeignKeyDefinition),
        unique_constraints : Array(UniqueDefinition),
        indexes : Array(IndexDefinition)

      record CreateTable,
        table : TableDefinition,
        if_not_exists : Bool = false
      record DropTable, table_name : String
      record AddColumn, table_name : String, column : ColumnDefinition
      record RenameColumn, table_name : String, from : String, to : String
      record CreateIndex, table_name : String, index : IndexDefinition
      record DropIndex, name : String
      record RawSQL, name : String, sql : String

      alias Operation = CreateTable | DropTable | AddColumn | RenameColumn |
                        CreateIndex | DropIndex | RawSQL

      def self.validate_identifier(identifier : String) : Nil
        if identifier.empty? || identifier.includes?('\0')
          raise ArgumentError.new(
            "Schema identifier must not be empty or contain NUL: #{identifier.inspect}"
          )
        end
      end
    end
  end
end
