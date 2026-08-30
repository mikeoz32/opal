module LF
  module Data
    module Schema
      class MigrationSourceGenerator
        CLASS_NAME = /\A[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*\z/

        def generate(
          plan : DiffPlan,
          *,
          version : Int64,
          name : String,
          class_name : String,
          allow_destructive : Bool = false,
        ) : String
          validate_request!(version, name, class_name)
          operations = plan.operations(allow_destructive: allow_destructive)
          raise EmptySchemaDiffError.new if operations.empty?

          String.build do |source|
            source << "require \"opal/data\"\n\n"
            source << "class " << class_name << " < LF::Data::Migration\n"
            source << "  def version : Int64\n"
            source << "    " << version << "_i64\n"
            source << "  end\n\n"
            source << "  def name : String\n"
            source << "    " << name.inspect << "\n"
            source << "  end\n\n"
            source << "  def up(schema : LF::Data::SchemaEditor) : Nil\n"
            operations.each { |operation| render_operation(source, operation) }
            source << "  end\n"
            source << "end\n"
          end
        end

        private def validate_request!(
          version : Int64,
          name : String,
          class_name : String,
        ) : Nil
          if version <= 0
            raise MigrationSourceGenerationError.new(
              "migration version must be positive"
            )
          end
          if name.empty? || name.includes?('\0')
            raise MigrationSourceGenerationError.new(
              "migration name must not be empty or contain NUL"
            )
          end
          unless CLASS_NAME.matches?(class_name)
            raise MigrationSourceGenerationError.new(
              "migration class name must be a Crystal constant path"
            )
          end
        end

        private def render_operation(source : IO, operation : Operation) : Nil
          case operation
          when CreateTable
            render_create_table(source, operation.table)
          when DropTable
            line(source, %(schema.drop_table(#{operation.table_name.inspect})))
          when RenameTable
            line(
              source,
              %(schema.rename_table(#{operation.from.inspect}, #{operation.to.inspect}))
            )
          when AddColumn
            line(source, %(schema.add_column(#{operation.table_name.inspect}) do |table|))
            render_column(source, operation.column, 6)
            line(source, "end")
          when RenameColumn
            line(
              source,
              "schema.rename_column(#{operation.table_name.inspect}, " \
              "#{operation.from.inspect}, #{operation.to.inspect})"
            )
          when CreateIndex
            arguments = operation.index.columns.map(&.inspect).join(", ")
            suffix = operation.index.unique? ? ", unique: true" : ""
            line(
              source,
              "schema.create_index(#{operation.table_name.inspect}, " \
              "#{operation.index.name.inspect}, #{arguments}#{suffix})"
            )
          when DropIndex
            line(source, %(schema.drop_index(#{operation.name.inspect})))
          when RawSQL
            line(
              source,
              %(schema.raw(#{operation.name.inspect}, #{operation.sql.inspect}))
            )
          end
        end

        private def render_create_table(
          source : IO,
          table : TableDefinition,
        ) : Nil
          line(source, %(schema.create_table(#{table.name.inspect}) do |table|))
          generated = table.columns.find(&.generated?)
          table.columns.each { |column| render_column(source, column, 6) }
          unless generated
            if primary_key = table.primary_key
              arguments = primary_key.columns.map(&.inspect).join(", ")
              suffix = primary_key.name ? ", name: #{primary_key.name.inspect}" : ""
              line(source, "table.primary_key(#{arguments}#{suffix})", 6)
            end
          end
          table.foreign_keys.each do |foreign_key|
            unless foreign_key.local_columns.size == 1 &&
                   foreign_key.referenced_columns.size == 1
              raise MigrationSourceGenerationError.new(
                "composite foreign-key source generation is not supported"
              )
            end
            suffix = foreign_key.name ? ", name: #{foreign_key.name.inspect}" : ""
            line(
              source,
              "table.foreign_key(#{foreign_key.local_columns.first.inspect}, " \
              "references_table: #{foreign_key.referenced_table.inspect}, " \
              "references_column: #{foreign_key.referenced_columns.first.inspect}" \
              "#{suffix})",
              6
            )
          end
          table.unique_constraints.each do |unique|
            arguments = unique.columns.map(&.inspect).join(", ")
            suffix = unique.name ? ", name: #{unique.name.inspect}" : ""
            line(source, "table.unique(#{arguments}#{suffix})", 6)
          end
          table.indexes.each do |index|
            arguments = index.columns.map(&.inspect).join(", ")
            suffix = index.unique? ? ", unique: true" : ""
            line(
              source,
              "table.index(#{index.name.inspect}, #{arguments}#{suffix})",
              6
            )
          end
          line(source, "end")
        end

        private def render_column(
          source : IO,
          column : ColumnDefinition,
          indent : Int32,
        ) : Nil
          if column.generated?
            line(source, "table.generated_id(#{column.name.inspect})", indent)
            return
          end

          method = case column.type
                   when .string?    then "string"
                   when .text?      then "text"
                   when .bool?      then "bool"
                   when .int32?     then "int32"
                   when .int64?     then "int64"
                   when .float64?   then "float64"
                   when .timestamp? then "timestamp"
                   when .bytes?     then "bytes"
                   else
                     raise MigrationSourceGenerationError.new(
                       "unsupported column type #{column.type}"
                     )
                   end
          options = [] of String
          options << "null: false" unless column.nullable?
          if default = column.default
            options << "default: #{literal(default.value)}"
          end
          suffix = options.empty? ? "" : ", #{options.join(", ")}"
          line(
            source,
            "table.#{method}(#{column.name.inspect}#{suffix})",
            indent
          )
        end

        private def literal(value : Literal) : String
          case value
          when String
            value.inspect
          when Bool
            value.to_s
          when Int32
            "#{value}_i32"
          when Int64
            "#{value}_i64"
          when Float64
            "#{value}_f64"
          when Time
            encoded = value.to_utc.to_rfc3339(fraction_digits: 9)
            "Time::Format::RFC_3339.parse(#{encoded.inspect})"
          when Bytes
            return "Bytes.new(0)" if value.empty?

            "Bytes[#{value.map { |byte| "0x#{byte.to_s(16).rjust(2, '0')}" }.join(", ")}]"
          else
            raise MigrationSourceGenerationError.new(
              "unsupported schema literal #{value.class}"
            )
          end
        end

        private def line(source : IO, text : String, indent : Int32 = 4) : Nil
          source << (" " * indent) << text << '\n'
        end
      end
    end
  end
end
