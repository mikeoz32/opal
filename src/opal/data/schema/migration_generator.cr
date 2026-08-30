module LF
  module Data
    module Schema
      class MigrationGenerator
        def initialize(@source : DataSource)
        end

        def plan(
          model : Model,
          options : DiffOptions = DiffOptions.new,
        ) : DiffPlan
          Differ.new(@source.dialect).diff(
            model,
            @source.inspect_schema(options.ignored_tables),
            options
          )
        end

        def generate(
          model : Model,
          *,
          version : Int64,
          name : String,
          class_name : String,
          options : DiffOptions = DiffOptions.new,
          allow_destructive : Bool = false,
        ) : String
          MigrationSourceGenerator.new.generate(
            plan(model, options),
            version: version,
            name: name,
            class_name: class_name,
            allow_destructive: allow_destructive
          )
        end
      end
    end
  end
end
