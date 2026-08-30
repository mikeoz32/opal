module LF
  module Data
    module Schema
      class ModelBuilder
        @tables = [] of TableDefinition
        @table_names = Set(String).new

        def table(name : String, & : TableBuilder ->) : Nil
          unless @table_names.add?(name)
            raise ArgumentError.new("Duplicate schema table #{name.inspect}")
          end

          builder = TableBuilder.new(name)
          yield builder
          @tables << builder.build
        end

        def build : Model
          Model.new(@tables)
        end
      end

      class Model
        RESERVED_TABLES = {"_lf_migrations"}

        getter tables : Array(TableDefinition)

        def self.build(& : ModelBuilder ->) : self
          builder = ModelBuilder.new
          yield builder
          builder.build
        end

        def initialize(tables : Enumerable(TableDefinition))
          @tables = tables.to_a.sort_by(&.name)
          validate!
        end

        def table(name : String) : TableDefinition?
          tables.find { |candidate| candidate.name == name }
        end

        private def validate! : Nil
          table_names = Set(String).new
          index_names = Set(String).new
          tables.each do |table|
            Schema.validate_identifier(table.name)
            if RESERVED_TABLES.includes?(table.name)
              raise ArgumentError.new(
                "Schema table #{table.name.inspect} is reserved by Opal Data"
              )
            end
            unless table_names.add?(table.name)
              raise ArgumentError.new("Duplicate schema table #{table.name.inspect}")
            end
            table.indexes.each do |index|
              unless index_names.add?(index.name)
                raise ArgumentError.new("Duplicate schema index #{index.name.inspect}")
              end
            end
          end

          tables.each do |table|
            table.foreign_keys.each do |foreign_key|
              referenced = self.table(foreign_key.referenced_table)
              unless referenced
                raise ArgumentError.new(
                  "Foreign key on #{table.name.inspect} references missing table " \
                  "#{foreign_key.referenced_table.inspect}"
                )
              end
              if foreign_key.local_columns.size != foreign_key.referenced_columns.size
                raise ArgumentError.new(
                  "Foreign key on #{table.name.inspect} has mismatched column counts"
                )
              end
              referenced_names = referenced.columns.map(&.name).to_set
              foreign_key.referenced_columns.each do |column|
                unless referenced_names.includes?(column)
                  raise ArgumentError.new(
                    "Foreign key on #{table.name.inspect} references missing column " \
                    "#{foreign_key.referenced_table}.#{column}"
                  )
                end
              end
            end
          end
        end
      end
    end
  end
end
