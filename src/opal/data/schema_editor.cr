module LF
  module Data
    class SchemaEditor
      def initialize(
        @renderer : SchemaRenderer,
        @observer : SchemaRenderer::StatementObserver? = nil,
      )
      end

      def create_table(name : String, & : Schema::TableBuilder ->) : Nil
        builder = Schema::TableBuilder.new(name)
        yield builder
        execute(Schema::CreateTable.new(builder.build))
      end

      def drop_table(name : String) : Nil
        Schema.validate_identifier(name)
        execute(Schema::DropTable.new(name))
      end

      def add_column(table_name : String, & : Schema::TableBuilder ->) : Nil
        Schema.validate_identifier(table_name)
        builder = Schema::TableBuilder.new(table_name)
        yield builder
        definition = builder.build
        unless definition.columns.size == 1
          raise ArgumentError.new("add_column must define exactly one column")
        end
        unless definition.primary_key.nil? &&
               definition.foreign_keys.empty? &&
               definition.unique_constraints.empty? &&
               definition.indexes.empty? &&
               !definition.columns.first.generated?
          raise ArgumentError.new("add_column must define one plain column")
        end

        execute(
          Schema::AddColumn.new(table_name, definition.columns.first)
        )
      end

      def rename_column(table_name : String, from : String, to : String) : Nil
        Schema.validate_identifier(table_name)
        Schema.validate_identifier(from)
        Schema.validate_identifier(to)
        execute(Schema::RenameColumn.new(table_name, from, to))
      end

      def create_index(
        table_name : String,
        name : String,
        *columns : String,
        unique : Bool = false,
      ) : Nil
        Schema.validate_identifier(table_name)
        Schema.validate_identifier(name)
        validated_columns = columns.to_a
        if validated_columns.empty?
          raise ArgumentError.new("Schema index must reference at least one column")
        end
        validated_columns.each { |column| Schema.validate_identifier(column) }
        execute(
          Schema::CreateIndex.new(
            table_name,
            Schema::IndexDefinition.new(name, validated_columns, unique)
          )
        )
      end

      def drop_index(name : String) : Nil
        Schema.validate_identifier(name)
        execute(Schema::DropIndex.new(name))
      end

      def raw(name : String, sql : String) : Nil
        Schema.validate_identifier(name)
        raise ArgumentError.new("Raw schema SQL must not be empty") if sql.empty?

        execute(Schema::RawSQL.new(name, sql))
      end

      private def execute(operation : Schema::Operation) : Nil
        @renderer.execute(operation, @observer)
      end
    end
  end
end
