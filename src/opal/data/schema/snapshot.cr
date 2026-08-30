module LF
  module Data
    module Schema
      record ColumnSnapshot,
        name : String,
        type : ColumnType,
        nullable : Bool,
        default : DefaultValue?,
        generated : Bool,
        default_expression : String? = nil do
        def nullable? : Bool
          nullable
        end

        def generated? : Bool
          generated
        end

        def has_default? : Bool
          !default.nil? || !default_expression.nil?
        end

        def self.from_definition(column : ColumnDefinition) : self
          new(
            column.name,
            column.type,
            column.nullable,
            column.default,
            column.generated
          )
        end
      end

      record TableSnapshot,
        name : String,
        columns : Array(ColumnSnapshot),
        primary_key : PrimaryKeyDefinition?,
        foreign_keys : Array(ForeignKeyDefinition),
        unique_constraints : Array(UniqueDefinition),
        indexes : Array(IndexDefinition) do
        def self.from_definition(table : TableDefinition) : self
          new(
            table.name,
            table.columns.map { |column| ColumnSnapshot.from_definition(column) },
            table.primary_key,
            table.foreign_keys.dup,
            table.unique_constraints.dup,
            table.indexes.dup
          )
        end

        def column(name : String) : ColumnSnapshot?
          columns.find { |candidate| candidate.name == name }
        end
      end

      class Snapshot
        getter tables : Array(TableSnapshot)

        def self.empty : self
          new
        end

        def self.from_model(model : Model) : self
          new(model.tables.map { |table| TableSnapshot.from_definition(table) })
        end

        def initialize(tables : Enumerable(TableSnapshot) = [] of TableSnapshot)
          @tables = tables.to_a.sort_by(&.name)
          names = Set(String).new
          @tables.each do |table|
            unless names.add?(table.name)
              raise ArgumentError.new("Duplicate inspected schema table #{table.name.inspect}")
            end
          end
        end

        def table(name : String) : TableSnapshot?
          tables.find { |candidate| candidate.name == name }
        end
      end
    end
  end
end
