module LF
  module Data
    module Schema
      enum DiffSafety
        Safe
        Destructive
      end

      record DiffStep,
        operation : Operation,
        safety : DiffSafety,
        description : String do
        def self.safe(operation : Operation, description : String) : self
          new(operation, DiffSafety::Safe, description)
        end

        def self.destructive(operation : Operation, description : String) : self
          new(operation, DiffSafety::Destructive, description)
        end

        def destructive? : Bool
          safety.destructive?
        end
      end

      record DiffDiagnostic, code : Symbol, message : String

      class DiffOptions
        getter table_renames = {} of String => String
        getter column_renames = {} of Tuple(String, String) => String
        getter ignored_tables = Set{"_lf_migrations"}

        def rename_table(from : String, to : String) : self
          Schema.validate_identifier(from)
          Schema.validate_identifier(to)
          if table_renames.has_key?(from)
            raise ArgumentError.new("Duplicate table rename hint for #{from.inspect}")
          end
          if table_renames.has_value?(to)
            raise ArgumentError.new("Duplicate table rename target #{to.inspect}")
          end
          table_renames[from] = to
          self
        end

        def rename_column(table : String, from : String, to : String) : self
          Schema.validate_identifier(table)
          Schema.validate_identifier(from)
          Schema.validate_identifier(to)
          key = {table, from}
          if column_renames.has_key?(key)
            raise ArgumentError.new(
              "Duplicate column rename hint for #{table}.#{from}"
            )
          end
          if column_renames.any? { |candidate, target| candidate[0] == table && target == to }
            raise ArgumentError.new(
              "Duplicate column rename target #{table}.#{to}"
            )
          end
          column_renames[key] = to
          self
        end

        def ignore_table(name : String) : self
          Schema.validate_identifier(name)
          ignored_tables << name
          self
        end
      end

      class DiffPlan
        getter dialect_name : String
        getter steps : Array(DiffStep)
        getter diagnostics : Array(DiffDiagnostic)

        def initialize(
          @dialect_name : String,
          @steps : Array(DiffStep) = [] of DiffStep,
          @diagnostics : Array(DiffDiagnostic) = [] of DiffDiagnostic,
        )
        end

        def empty? : Bool
          steps.empty? && diagnostics.empty?
        end

        def executable? : Bool
          diagnostics.empty?
        end

        def destructive? : Bool
          steps.any?(&.destructive?)
        end

        def operations(*, allow_destructive : Bool = false) : Array(Operation)
          unless executable?
            raise UnresolvedSchemaDiffError.new(diagnostics)
          end
          destructive = steps.select(&.destructive?)
          if !allow_destructive && !destructive.empty?
            raise UnsafeSchemaChangeError.new(destructive.map(&.description))
          end
          steps.map(&.operation)
        end
      end

      class Differ
        def initialize(@dialect : Dialect)
        end

        def diff(
          desired : Model,
          actual : Snapshot,
          options : DiffOptions = DiffOptions.new,
        ) : DiffPlan
          steps = [] of DiffStep
          diagnostics = [] of DiffDiagnostic
          managed_names = desired.tables.map(&.name).to_set
          conflicting_ignored = managed_names & options.ignored_tables
          unless conflicting_ignored.empty?
            diagnostics << DiffDiagnostic.new(
              :managed_table_ignored,
              "Declared schema tables cannot also be ignored: " \
              "#{conflicting_ignored.to_a.sort.join(", ")}"
            )
            return DiffPlan.new(@dialect.name, steps, diagnostics)
          end
          filtered = Snapshot.new(
            actual.tables.reject { |table| options.ignored_tables.includes?(table.name) }
          )

          validate_table_renames(desired, filtered, options, diagnostics)
          return DiffPlan.new(@dialect.name, steps, diagnostics) unless diagnostics.empty?
          transformed = transform_snapshot(filtered, options)
          options.table_renames.to_a.sort_by(&.[0]).each do |from, to|
            steps << DiffStep.safe(
              RenameTable.new(from, to),
              "rename table #{from} to #{to}"
            )
          end

          validate_column_renames(desired, transformed, options, diagnostics)
          return DiffPlan.new(@dialect.name, steps, diagnostics) unless diagnostics.empty?
          transformed = transform_columns(transformed, options)
          options.column_renames.to_a.sort_by { |entry| {entry[0][0], entry[0][1]} }
            .each do |entry|
              table, from = entry[0]
              to = entry[1]
              steps << DiffStep.safe(
                RenameColumn.new(table, from, to),
                "rename #{table}.#{from} to #{to}"
              )
            end

          desired_by_name = desired.tables.to_h { |table| {table.name, table} }
          actual_by_name = transformed.tables.to_h { |table| {table.name, table} }
          missing_names = desired_by_name.keys.reject { |name| actual_by_name.has_key?(name) }
          ordered_missing_tables(
            missing_names,
            desired_by_name,
            diagnostics
          ).each do |table|
            steps << DiffStep.safe(
              CreateTable.new(table),
              "create table #{table.name}"
            )
          end

          (desired_by_name.keys & actual_by_name.keys).sort.each do |table_name|
            compare_table(
              desired_by_name[table_name],
              actual_by_name[table_name],
              steps,
              diagnostics
            )
          end

          extra_names = actual_by_name.keys.reject { |name| desired_by_name.has_key?(name) }
          ordered_extra_tables(
            extra_names,
            actual_by_name,
            diagnostics
          ).each do |table|
            steps << DiffStep.destructive(
              DropTable.new(table.name),
              "drop table #{table.name}"
            )
          end

          DiffPlan.new(@dialect.name, steps, diagnostics)
        end

        private def validate_table_renames(
          desired : Model,
          actual : Snapshot,
          options : DiffOptions,
          diagnostics : Array(DiffDiagnostic),
        ) : Nil
          options.table_renames.each do |from, to|
            unless actual.table(from)
              diagnostics << DiffDiagnostic.new(
                :invalid_table_rename,
                "Table rename source #{from.inspect} does not exist"
              )
            end
            unless desired.table(to)
              diagnostics << DiffDiagnostic.new(
                :invalid_table_rename,
                "Table rename target #{to.inspect} is not declared"
              )
            end
            if from != to && actual.table(to)
              diagnostics << DiffDiagnostic.new(
                :invalid_table_rename,
                "Table rename target #{to.inspect} already exists"
              )
            end
          end
        end

        private def validate_column_renames(
          desired : Model,
          actual : Snapshot,
          options : DiffOptions,
          diagnostics : Array(DiffDiagnostic),
        ) : Nil
          options.column_renames.each do |key, to|
            table_name, from = key
            table = actual.table(table_name)
            desired_table = desired.table(table_name)
            unless table && table.column(from)
              diagnostics << DiffDiagnostic.new(
                :invalid_column_rename,
                "Column rename source #{table_name}.#{from} does not exist"
              )
            end
            unless desired_table && desired_table.columns.any? { |column| column.name == to }
              diagnostics << DiffDiagnostic.new(
                :invalid_column_rename,
                "Column rename target #{table_name}.#{to} is not declared"
              )
            end
            if from != to && table.try(&.column(to))
              diagnostics << DiffDiagnostic.new(
                :invalid_column_rename,
                "Column rename target #{table_name}.#{to} already exists"
              )
            end
          end
        end

        private def transform_snapshot(
          snapshot : Snapshot,
          options : DiffOptions,
        ) : Snapshot
          Snapshot.new(snapshot.tables.map do |table|
            renamed = options.table_renames[table.name]? || table.name
            TableSnapshot.new(
              renamed,
              table.columns,
              table.primary_key,
              table.foreign_keys.map do |foreign_key|
                ForeignKeyDefinition.new(
                  foreign_key.local_columns,
                  options.table_renames[foreign_key.referenced_table]? ||
                  foreign_key.referenced_table,
                  foreign_key.referenced_columns,
                  foreign_key.name
                )
              end,
              table.unique_constraints,
              table.indexes
            )
          end)
        end

        private def transform_columns(
          snapshot : Snapshot,
          options : DiffOptions,
        ) : Snapshot
          Snapshot.new(snapshot.tables.map do |table|
            rename = ->(column : String) do
              options.column_renames[{table.name, column}]? || column
            end
            TableSnapshot.new(
              table.name,
              table.columns.map do |column|
                ColumnSnapshot.new(
                  rename.call(column.name),
                  column.type,
                  column.nullable,
                  column.default,
                  column.generated,
                  column.default_expression
                )
              end,
              table.primary_key.try do |primary_key|
                PrimaryKeyDefinition.new(
                  primary_key.columns.map { |column| rename.call(column) },
                  primary_key.name
                )
              end,
              table.foreign_keys.map do |foreign_key|
                referenced_rename = ->(column : String) do
                  options.column_renames[
                    {foreign_key.referenced_table, column},
                  ]? || column
                end
                ForeignKeyDefinition.new(
                  foreign_key.local_columns.map { |column| rename.call(column) },
                  foreign_key.referenced_table,
                  foreign_key.referenced_columns.map do |column|
                    referenced_rename.call(column)
                  end,
                  foreign_key.name
                )
              end,
              table.unique_constraints.map do |unique|
                UniqueDefinition.new(
                  unique.columns.map { |column| rename.call(column) },
                  unique.name
                )
              end,
              table.indexes.map do |index|
                IndexDefinition.new(
                  index.name,
                  index.columns.map { |column| rename.call(column) },
                  index.unique
                )
              end
            )
          end)
        end

        private def compare_table(
          desired : TableDefinition,
          actual : TableSnapshot,
          steps : Array(DiffStep),
          diagnostics : Array(DiffDiagnostic),
        ) : Nil
          desired_columns = desired.columns.to_h { |column| {column.name, column} }
          actual_columns = actual.columns.to_h { |column| {column.name, column} }

          desired_columns.keys.sort.each do |name|
            expected = desired_columns[name]
            if inspected = actual_columns[name]?
              unless column_matches?(expected, inspected)
                diagnostics << DiffDiagnostic.new(
                  :column_definition_changed,
                  "Column #{desired.name}.#{name} differs from the declared definition"
                )
              end
            else
              steps << DiffStep.safe(
                AddColumn.new(desired.name, expected),
                "add column #{desired.name}.#{name}"
              )
            end
          end

          (actual_columns.keys - desired_columns.keys).sort.each do |name|
            diagnostics << DiffDiagnostic.new(
              :column_removed,
              "Column #{desired.name}.#{name} is absent from the declared schema; " \
              "write an explicit destructive migration"
            )
          end

          compare_constraints(desired, actual, diagnostics)
          compare_indexes(desired, actual, steps)
        end

        private def column_matches?(
          desired : ColumnDefinition,
          actual : ColumnSnapshot,
        ) : Bool
          @dialect.schema_type_matches?(desired.type, actual.type) &&
            desired.nullable == actual.nullable &&
            desired.generated == actual.generated &&
            @dialect.schema_default_matches?(desired.default, actual)
        end

        private def compare_constraints(
          desired : TableDefinition,
          actual : TableSnapshot,
          diagnostics : Array(DiffDiagnostic),
        ) : Nil
          primary_matches = definition_matches?(desired.primary_key, actual.primary_key) do |left, right|
            left.columns == right.columns && names_match?(left.name, right.name)
          end
          unique_matches = collection_matches?(
            desired.unique_constraints,
            actual.unique_constraints
          ) do |left, right|
            left.columns == right.columns && names_match?(left.name, right.name)
          end
          foreign_matches = collection_matches?(
            desired.foreign_keys,
            actual.foreign_keys
          ) do |left, right|
            left.local_columns == right.local_columns &&
              left.referenced_table == right.referenced_table &&
              left.referenced_columns == right.referenced_columns &&
              names_match?(left.name, right.name)
          end
          return if primary_matches && unique_matches && foreign_matches

          diagnostics << DiffDiagnostic.new(
            :constraint_definition_changed,
            "Constraints on table #{desired.name} differ; write an explicit migration"
          )
        end

        private def definition_matches?(left, right, &)
          return true if left.nil? && right.nil?
          return false if left.nil? || right.nil?
          yield left.not_nil!, right.not_nil!
        end

        private def collection_matches?(left : Array(T), right : Array(T), &) : Bool forall T
          return false unless left.size == right.size
          remaining = right.dup
          left.all? do |candidate|
            index = remaining.index { |inspected| yield candidate, inspected }
            if index
              remaining.delete_at(index)
              true
            else
              false
            end
          end
        end

        private def names_match?(desired : String?, actual : String?) : Bool
          desired.nil? || actual.nil? || desired == actual
        end

        private def compare_indexes(
          desired : TableDefinition,
          actual : TableSnapshot,
          steps : Array(DiffStep),
        ) : Nil
          desired_indexes = desired.indexes.to_h { |index| {index.name, index} }
          actual_indexes = actual.indexes.to_h { |index| {index.name, index} }

          desired_indexes.keys.sort.each do |name|
            expected = desired_indexes[name]
            if inspected = actual_indexes[name]?
              next if expected == inspected

              steps << DiffStep.destructive(
                DropIndex.new(name),
                "replace index #{name}"
              )
              steps << DiffStep.safe(
                CreateIndex.new(desired.name, expected),
                "create index #{name}"
              )
            else
              steps << DiffStep.safe(
                CreateIndex.new(desired.name, expected),
                "create index #{name}"
              )
            end
          end

          (actual_indexes.keys - desired_indexes.keys).sort.each do |name|
            steps << DiffStep.destructive(
              DropIndex.new(name),
              "drop index #{name}"
            )
          end
        end

        private def ordered_missing_tables(
          names : Array(String),
          tables : Hash(String, TableDefinition),
          diagnostics : Array(DiffDiagnostic),
        ) : Array(TableDefinition)
          remaining = names.to_set
          ordered = [] of TableDefinition
          until remaining.empty?
            ready = remaining.select do |name|
              tables[name].foreign_keys.none? do |foreign_key|
                remaining.includes?(foreign_key.referenced_table)
              end
            end.to_a.sort
            if ready.empty?
              diagnostics << DiffDiagnostic.new(
                :cyclic_table_dependencies,
                "New tables contain a foreign-key cycle: #{remaining.to_a.sort.join(", ")}"
              )
              return ordered + remaining.to_a.sort.map { |name| tables[name] }
            end
            ready.each do |name|
              remaining.delete(name)
              ordered << tables[name]
            end
          end
          ordered
        end

        private def ordered_extra_tables(
          names : Array(String),
          tables : Hash(String, TableSnapshot),
          diagnostics : Array(DiffDiagnostic),
        ) : Array(TableSnapshot)
          remaining = names.to_set
          ordered = [] of TableSnapshot
          until remaining.empty?
            ready = remaining.select do |name|
              tables[name].foreign_keys.none? do |foreign_key|
                remaining.includes?(foreign_key.referenced_table)
              end
            end.to_a.sort
            if ready.empty?
              diagnostics << DiffDiagnostic.new(
                :cyclic_table_drop_dependencies,
                "Removed tables contain a foreign-key cycle: " \
                "#{remaining.to_a.sort.join(", ")}"
              )
              return ordered + remaining.to_a.sort.map { |name| tables[name] }
            end
            ready.each do |name|
              remaining.delete(name)
              ordered << tables[name]
            end
          end
          ordered.reverse
        end
      end
    end
  end
end
