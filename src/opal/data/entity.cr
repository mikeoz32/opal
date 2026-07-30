module LF
  module Data
    module Entity
      macro included
        Fields = LF::Data::Query::FieldSet({{@type}}).new

        {% verbatim do %}
          def self.__lf_validate_entity : Nil
            {% begin %}
            {% entity = @type %}
            {% unless entity < Reference %}
              {% raise "#{entity} must be a reference class to include LF::Data::Entity" %}
            {% end %}

            {% if table_annotation = entity.annotation(LF::Data::Table) %}
              {% if table_annotation[:name] %}
                {% table_name = table_annotation[:name] %}
              {% elsif table_annotation.args.size > 0 %}
                {% table_name = table_annotation.args.first %}
              {% else %}
                {% table_name = entity.name.stringify
                     .split("::").last
                     .gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
                     .gsub(/([a-z0-9])([A-Z])/, "\\1_\\2")
                     .downcase %}
              {% end %}
            {% else %}
              {% table_name = entity.name.stringify
                   .split("::").last
                   .gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
                   .gsub(/([a-z0-9])([A-Z])/, "\\1_\\2")
                   .downcase %}
            {% end %}
            {% if table_name.empty? || table_name.includes?("\0") %}
              {% raise "#{entity} table name must not be empty or contain NUL" %}
            {% end %}

            {% persistent_ivars = entity.instance_vars.reject do |ivar|
                 column_ann = ivar.annotation(LF::Data::Column)
                 column_ann && column_ann[:ignore]
               end %}
            {% ignored_ivars = entity.instance_vars.select do |ivar|
                 column_ann = ivar.annotation(LF::Data::Column)
                 column_ann && column_ann[:ignore]
               end %}
            {% for ivar in ignored_ivars %}
              {% unless ivar.type.resolve.nilable? || ivar.has_default_value? %}
                {% raise "#{entity} ignored field #{ivar.name} must be nilable or declare a default for constructor-free hydration" %}
              {% end %}
            {% end %}
            {% id_ivars = persistent_ivars.select { |ivar| ivar.annotation(LF::Data::Id) } %}
            {% unless id_ivars.size == 1 %}
              {% names = id_ivars.map(&.name.stringify).join(", ") %}
              {% raise "#{entity} must define exactly one LF::Data::Id field; found: #{names}" %}
            {% end %}

            {% effective_columns = [] of String %}
            {% for ivar in persistent_ivars %}
              {% column_annotation = ivar.annotation(LF::Data::Column) %}
              {% column_name = (column_annotation && column_annotation[:name]) || ivar.name.stringify %}
              {% if column_name.empty? || column_name.includes?("\0") %}
                {% raise "#{entity} column name for field #{ivar.name} must not be empty or contain NUL" %}
              {% end %}
              {% if effective_columns.includes?(column_name) %}
                {% raise "#{entity} maps more than one field to column #{column_name.id}" %}
              {% end %}
              {% effective_columns << column_name %}
            {% end %}

            {% id_ivar = id_ivars.first %}
            {% id_annotation = id_ivar.annotation(LF::Data::Id) %}
            {% id_type = id_ivar.type.resolve %}
            {% generated_id = id_annotation[:generated] || false %}
            {% if generated_id %}
              {% non_nil_id_types = id_type.union_types.reject { |type| type == Nil } %}
              {% valid_generated_type = id_type.nilable? &&
                                        non_nil_id_types.size == 1 &&
                                        ["Int32", "Int64"].includes?(non_nil_id_types.first.stringify) %}
              {% unless valid_generated_type %}
                {% raise "#{entity} field #{id_ivar.name} generated ID must be Int32? or Int64?, not #{id_type}" %}
              {% end %}
            {% elsif id_type.nilable? %}
              {% raise "#{entity} field #{id_ivar.name} assigned ID must not be nilable" %}
            {% end %}

            {% version_ivars = persistent_ivars.select { |ivar| ivar.annotation(LF::Data::Version) } %}
            {% if version_ivars.size > 1 %}
              {% names = version_ivars.map(&.name.stringify).join(", ") %}
              {% raise "#{entity} defines multiple LF::Data::Version fields: #{names}" %}
            {% end %}
            {% if version_ivars.size == 1 %}
              {% version_ivar = version_ivars.first %}
              {% version_type = version_ivar.type.resolve %}
              {% unless version_type.stringify == "Int64" %}
                {% raise "#{entity} field #{version_ivar.name} version must be non-nil Int64, not #{version_type}" %}
              {% end %}
              {% setter_name = "#{version_ivar.name}=" %}
              {% if entity.methods.any? { |method| method.name.stringify == setter_name } %}
                {% raise "#{entity} field #{version_ivar.name} version must not expose public setter #{setter_name.id}" %}
              {% end %}
            {% end %}

            {% portable_types = [
                 "String",
                 "Bool",
                 "Int32",
                 "Int64",
                 "Float32",
                 "Float64",
                 "Time",
                 "Slice(UInt8)",
               ] %}
            {% for ivar in persistent_ivars %}
              {% column_annotation = ivar.annotation(LF::Data::Column) %}
              {% converter = column_annotation && column_annotation[:converter] %}
              {% unless converter %}
                {% field_type = ivar.type.resolve %}
                {% if field_type.nilable? %}
                  {% non_nil_types = field_type.union_types.reject { |type| type == Nil } %}
                  {% direct_type = non_nil_types.size == 1 ? non_nil_types.first : field_type %}
                {% else %}
                  {% direct_type = field_type %}
                {% end %}
                {% unless portable_types.includes?(direct_type.stringify) %}
                  {% raise "#{entity} field #{ivar.name} type #{field_type} is not directly representable by DB::Any; define LF::Data::Column converter" %}
                {% end %}
              {% end %}
            {% end %}
            {% end %}
          end

          def self.__lf_entity? : Bool
            true
          end

          def self.__lf_table_name : String
            {% begin %}
              {% if table_annotation = @type.annotation(LF::Data::Table) %}
                {% if table_annotation[:name] %}
                  {% table_name = table_annotation[:name] %}
                {% elsif table_annotation.args.size > 0 %}
                  {% table_name = table_annotation.args.first %}
                {% else %}
                  {% table_name = @type.name.stringify
                       .split("::").last
                       .gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
                       .gsub(/([a-z0-9])([A-Z])/, "\\1_\\2")
                       .downcase %}
                {% end %}
              {% else %}
                {% table_name = @type.name.stringify
                     .split("::").last
                     .gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
                     .gsub(/([a-z0-9])([A-Z])/, "\\1_\\2")
                     .downcase %}
              {% end %}
              {{table_name}}
            {% end %}
          end

          def self.__lf_persistent_columns
            {% begin %}
              {% columns = [] of String %}
              {% for ivar in @type.instance_vars %}
                {% column_annotation = ivar.annotation(LF::Data::Column) %}
                {% unless column_annotation && column_annotation[:ignore] %}
                  {% columns << ((column_annotation && column_annotation[:name]) || ivar.name.stringify) %}
                {% end %}
              {% end %}
              { {{columns.splat}} }
            {% end %}
          end

          def self.__lf_id_column : String
            {% begin %}
              {% id_ivar = @type.instance_vars.find do |ivar|
                   column_annotation = ivar.annotation(LF::Data::Column)
                   !(column_annotation && column_annotation[:ignore]) &&
                     ivar.annotation(LF::Data::Id)
                 end %}
              {% column_annotation = id_ivar.annotation(LF::Data::Column) %}
              {{(column_annotation && column_annotation[:name]) || id_ivar.name.stringify}}
            {% end %}
          end

          def self.__lf_generated_id? : Bool
            {% begin %}
              {% id_ivar = @type.instance_vars.find do |ivar|
                   column_annotation = ivar.annotation(LF::Data::Column)
                   !(column_annotation && column_annotation[:ignore]) &&
                     ivar.annotation(LF::Data::Id)
                 end %}
              {% id_annotation = id_ivar.annotation(LF::Data::Id) %}
              {{id_annotation[:generated] || false}}
            {% end %}
          end

          def self.__lf_version_column : String?
            {% begin %}
              {% version_ivar = @type.instance_vars.find do |ivar|
                   column_annotation = ivar.annotation(LF::Data::Column)
                   !(column_annotation && column_annotation[:ignore]) &&
                     ivar.annotation(LF::Data::Version)
                 end %}
              {% if version_ivar %}
                {% column_annotation = version_ivar.annotation(LF::Data::Column) %}
                {{(column_annotation && column_annotation[:name]) || version_ivar.name.stringify}}
              {% else %}
                nil
              {% end %}
            {% end %}
          end

          def self.__lf_hydrate(result : DB::ResultSet) : self
            LF::Data::Hydrator.validate_columns(
              result,
              {{@type.name.stringify}},
              __lf_persistent_columns
            )
            allocate.__lf_load_persistent_state(result)
          end

          def __lf_load_persistent_state(result : DB::ResultSet) : self
            {% for ivar in @type.instance_vars %}
              {% column_annotation = ivar.annotation(LF::Data::Column) %}
              {% if column_annotation && column_annotation[:ignore] %}
                {% if ivar.has_default_value? %}
                  @{{ivar.name}} = {{ivar.default_value}}
                {% else %}
                  @{{ivar.name}} = nil
                {% end %}
              {% else %}
                {% column_name = (column_annotation && column_annotation[:name]) || ivar.name.stringify %}
                begin
                  {% if converter = column_annotation && column_annotation[:converter] %}
                    @{{ivar.name}} = LF::Data::Converter.load(
                      result,
                      {{converter}},
                      {{ivar.type}}
                    )
                  {% else %}
                    @{{ivar.name}} = result.read({{ivar.type}})
                  {% end %}
                rescue error : LF::Data::MappingError
                  raise error
                rescue error
                  raise LF::Data::MappingError.new(
                    {{@type.name.stringify}},
                    {{ivar.name.stringify}},
                    {{column_name}},
                    error
                  )
                end
              {% end %}
            {% end %}
            self
          end

          def __lf_insert_args
            {% begin %}
            Tuple.new(
              {% for ivar in @type.instance_vars %}
                {% column_annotation = ivar.annotation(LF::Data::Column) %}
                {% id_annotation = ivar.annotation(LF::Data::Id) %}
                {% ignored = column_annotation && column_annotation[:ignore] %}
                {% generated_id = id_annotation && id_annotation[:generated] %}
                {% unless ignored || generated_id || ivar.annotation(LF::Data::Version) %}
                  {% if converter = column_annotation && column_annotation[:converter] %}
                    {% if ivar.type.resolve.nilable? %}
                      @{{ivar.name}}.nil? ? nil : LF::Data::Converter.dump(@{{ivar.name}}.not_nil!, {{converter}}),
                    {% else %}
                      LF::Data::Converter.dump(@{{ivar.name}}, {{converter}}),
                    {% end %}
                  {% else %}
                    @{{ivar.name}},
                  {% end %}
                {% end %}
              {% end %}
            )
            {% end %}
          end

          def __lf_update_args
            {% begin %}
            {% id_ivar = @type.instance_vars.find { |ivar| ivar.annotation(LF::Data::Id) } %}
            {% id_column_annotation = id_ivar.annotation(LF::Data::Column) %}
            Tuple.new(
              {% for ivar in @type.instance_vars %}
                {% column_annotation = ivar.annotation(LF::Data::Column) %}
                {% ignored = column_annotation && column_annotation[:ignore] %}
                {% unless ignored || ivar.annotation(LF::Data::Id) || ivar.annotation(LF::Data::Version) %}
                  {% if converter = column_annotation && column_annotation[:converter] %}
                    {% if ivar.type.resolve.nilable? %}
                      @{{ivar.name}}.nil? ? nil : LF::Data::Converter.dump(@{{ivar.name}}.not_nil!, {{converter}}),
                    {% else %}
                      LF::Data::Converter.dump(@{{ivar.name}}, {{converter}}),
                    {% end %}
                  {% else %}
                    @{{ivar.name}},
                  {% end %}
                {% end %}
              {% end %}
              {% if id_converter = id_column_annotation && id_column_annotation[:converter] %}
                {% if id_ivar.type.resolve.nilable? %}
                  @{{id_ivar.name}}.nil? ? nil : LF::Data::Converter.dump(@{{id_ivar.name}}.not_nil!, {{id_converter}}),
                {% else %}
                  LF::Data::Converter.dump(@{{id_ivar.name}}, {{id_converter}}),
                {% end %}
              {% else %}
                @{{id_ivar.name}},
              {% end %}
            )
            {% end %}
          end

          def __lf_delete_args
            {% begin %}
            {% id_ivar = @type.instance_vars.find { |ivar| ivar.annotation(LF::Data::Id) } %}
            {% id_column_annotation = id_ivar.annotation(LF::Data::Column) %}
            Tuple.new(
              {% if id_converter = id_column_annotation && id_column_annotation[:converter] %}
                {% if id_ivar.type.resolve.nilable? %}
                  @{{id_ivar.name}}.nil? ? nil : LF::Data::Converter.dump(@{{id_ivar.name}}.not_nil!, {{id_converter}})
                {% else %}
                  LF::Data::Converter.dump(@{{id_ivar.name}}, {{id_converter}})
                {% end %}
              {% else %}
                @{{id_ivar.name}}
              {% end %}
            )
            {% end %}
          end

          def self.__lf_find_args(id : T) forall T
            {% begin %}
            {% id_ivar = @type.instance_vars.find { |ivar| ivar.annotation(LF::Data::Id) } %}
            {% id_column_annotation = id_ivar.annotation(LF::Data::Column) %}
            Tuple.new(
              {% if id_converter = id_column_annotation && id_column_annotation[:converter] %}
                LF::Data::Converter.dump(id, {{id_converter}})
              {% else %}
                id
              {% end %}
            )
            {% end %}
          end

          def __lf_write_generated_id(value : Int64) : Nil
            {% begin %}
              {% id_ivar = @type.instance_vars.find { |ivar| ivar.annotation(LF::Data::Id) } %}
              {% id_annotation = id_ivar.annotation(LF::Data::Id) %}
              {% raise "#{@type} does not have a generated ID" unless id_annotation[:generated] %}
              {% id_type = id_ivar.type.resolve.union_types.reject { |type| type == Nil }.first %}
              {% if id_type.stringify == "Int32" %}
                @{{id_ivar.name}} = value.to_i32
              {% else %}
                @{{id_ivar.name}} = value
              {% end %}
              nil
            {% end %}
          end

          macro finished
            __lf_validate_entity
          end
        {% end %}
      end
    end
  end
end
