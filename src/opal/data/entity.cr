module LF
  module Data
    module Entity
      macro included
        Fields = LF::Data::Query::FieldSet({{@type}}).new
        Relations = LF::Data::RelationshipSet({{@type}}).new

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
                 (column_ann && column_ann[:ignore]) ||
                   ivar.annotation(LF::Data::BelongsTo) ||
                   ivar.annotation(LF::Data::HasOne) ||
                   ivar.annotation(LF::Data::HasMany)
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

            {% for relation_ivar in entity.instance_vars %}
              {% belongs_to = relation_ivar.annotation(LF::Data::BelongsTo) %}
              {% has_one = relation_ivar.annotation(LF::Data::HasOne) %}
              {% has_many = relation_ivar.annotation(LF::Data::HasMany) %}
              {% relationship_count = (belongs_to ? 1 : 0) +
                                      (has_one ? 1 : 0) +
                                      (has_many ? 1 : 0) %}
              {% if relationship_count > 0 %}
                {% if relationship_count > 1 %}
                  {% raise "#{entity} field #{relation_ivar.name} must declare exactly one relationship annotation" %}
                {% end %}
                {% if relation_ivar.annotation(LF::Data::Column) %}
                  {% raise "#{entity} relationship field #{relation_ivar.name} must not declare LF::Data::Column" %}
                {% end %}
                {% if relation_ivar.annotation(LF::Data::Id) || relation_ivar.annotation(LF::Data::Version) %}
                  {% raise "#{entity} relationship field #{relation_ivar.name} cannot be an ID or version" %}
                {% end %}

                {% relationship = belongs_to || has_one || has_many %}
                {% relationship_attributes = relationship.named_args.keys.map(&.stringify) %}
                {% if relationship_attributes.includes?("orphan_removal") %}
                  {% raise "#{entity} relationship #{relation_ivar.name} orphan removal is not supported" %}
                {% end %}
                {% supported_attributes = ["foreign_key", "cascade_persist", "cascade_remove"] %}
                {% unsupported_attributes = relationship_attributes.reject do |attribute|
                     supported_attributes.includes?(attribute)
                   end %}
                {% unless unsupported_attributes.empty? %}
                  {% raise "#{entity} relationship #{relation_ivar.name} has unsupported attributes: #{unsupported_attributes.join(", ")}" %}
                {% end %}
                {% foreign_key = relationship[:foreign_key] %}
                {% unless foreign_key && foreign_key.is_a?(StringLiteral) && !foreign_key.empty? %}
                  {% raise "#{entity} relationship #{relation_ivar.name} requires a non-empty String foreign_key" %}
                {% end %}
                {% for cascade_attribute in ["cascade_persist", "cascade_remove"] %}
                  {% if relationship_attributes.includes?(cascade_attribute) &&
                          !relationship[cascade_attribute].is_a?(BoolLiteral) %}
                    {% raise "#{entity} relationship #{relation_ivar.name} #{cascade_attribute.id} must be a Bool literal" %}
                  {% end %}
                {% end %}
                {% if belongs_to && relationship[:cascade_remove] %}
                  {% raise "#{entity} belongs_to #{relation_ivar.name} does not allow cascade_remove" %}
                {% end %}

                {% relationship_type = relation_ivar.type.resolve %}
                {% if has_many %}
                  {% unless relationship_type < Array && relationship_type.type_vars.size == 1 %}
                    {% raise "#{entity} has_many #{relation_ivar.name} must be Array(Target), not #{relationship_type}" %}
                  {% end %}
                  {% target_type = relationship_type.type_vars.first %}
                {% else %}
                  {% target_types = relationship_type.union_types.reject { |type| type == Nil } %}
                  {% unless relationship_type.nilable? && target_types.size == 1 %}
                    {% kind = belongs_to ? "belongs_to" : "has_one" %}
                    {% raise "#{entity} #{kind} #{relation_ivar.name} must be nilable Target?, not #{relationship_type}" %}
                  {% end %}
                  {% target_type = target_types.first %}
                {% end %}
                {% unless target_type < LF::Data::Entity %}
                  {% raise "#{entity} relationship #{relation_ivar.name} target #{target_type} must include LF::Data::Entity" %}
                {% end %}

                {% if belongs_to %}
                  {% foreign_key_owner = entity %}
                  {% referenced_type = target_type %}
                {% else %}
                  {% foreign_key_owner = target_type %}
                  {% referenced_type = entity %}
                {% end %}
                {% foreign_key_ivar = foreign_key_owner.instance_vars.find do |ivar|
                     ivar.name.stringify == foreign_key
                   end %}
                {% unless foreign_key_ivar %}
                  {% raise "#{entity} relationship #{relation_ivar.name} references missing foreign-key field #{foreign_key}" %}
                {% end %}
                {% foreign_key_column = foreign_key_ivar.annotation(LF::Data::Column) %}
                {% if (foreign_key_column && foreign_key_column[:ignore]) ||
                        foreign_key_ivar.annotation(LF::Data::BelongsTo) ||
                        foreign_key_ivar.annotation(LF::Data::HasOne) ||
                        foreign_key_ivar.annotation(LF::Data::HasMany) %}
                  {% raise "#{entity} relationship #{relation_ivar.name} foreign-key field #{foreign_key} must be persistent" %}
                {% end %}

                {% referenced_id = referenced_type.instance_vars.find { |ivar| ivar.annotation(LF::Data::Id) } %}
                {% referenced_id_annotation = referenced_id.annotation(LF::Data::Id) %}
                {% referenced_id_type = referenced_id.type.resolve %}
                {% if referenced_id_annotation[:generated] %}
                  {% referenced_lookup_type = referenced_id_type.union_types.reject { |type| type == Nil }.first %}
                {% else %}
                  {% referenced_lookup_type = referenced_id_type %}
                {% end %}
                {% foreign_key_types = foreign_key_ivar.type.resolve.union_types.reject { |type| type == Nil } %}
                {% unless foreign_key_types.size == 1 && foreign_key_types.first == referenced_lookup_type %}
                  {% raise "#{entity} relationship #{relation_ivar.name} foreign-key field #{foreign_key} must use #{referenced_lookup_type} or #{referenced_lookup_type}?, not #{foreign_key_ivar.type.resolve}" %}
                {% end %}
                {% referenced_id_column = referenced_id.annotation(LF::Data::Column) %}
                {% foreign_key_converter = foreign_key_column && foreign_key_column[:converter] %}
                {% referenced_converter = referenced_id_column && referenced_id_column[:converter] %}
                {% unless foreign_key_converter == referenced_converter %}
                  {% raise "#{entity} relationship #{relation_ivar.name} foreign-key field #{foreign_key} must use the referenced ID converter" %}
                {% end %}

                {% unless belongs_to %}
                  {% inverse = target_type.instance_vars.find do |candidate|
                       inverse_annotation = candidate.annotation(LF::Data::BelongsTo)
                       if inverse_annotation && inverse_annotation[:foreign_key] == foreign_key
                         inverse_types = candidate.type.resolve.union_types.reject { |type| type == Nil }
                         inverse_types.size == 1 && inverse_types.first == entity
                       else
                         false
                       end
                     end %}
                  {% unless inverse %}
                    {% kind = has_many ? "has_many" : "has_one" %}
                    {% raise "#{entity} #{kind} #{relation_ivar.name} requires an inverse belongs_to on #{target_type} using #{foreign_key}" %}
                  {% end %}
                {% end %}
              {% end %}
            {% end %}

            {% version_ivars = entity.instance_vars.select { |ivar| ivar.annotation(LF::Data::Version) } %}
            {% if version_ivars.size > 1 %}
              {% names = version_ivars.map(&.name.stringify).join(", ") %}
              {% raise "#{entity} defines multiple LF::Data::Version fields: #{names}" %}
            {% end %}
            {% if version_ivars.size == 1 %}
              {% version_ivar = version_ivars.first %}
              {% version_column = version_ivar.annotation(LF::Data::Column) %}
              {% if version_column && version_column[:ignore] %}
                {% raise "#{entity} field #{version_ivar.name} version must not be ignored" %}
              {% end %}
              {% if version_column && version_column[:converter] %}
                {% raise "#{entity} field #{version_ivar.name} version must not define a converter" %}
              {% end %}
              {% if version_ivar.annotation(LF::Data::Id) %}
                {% raise "#{entity} field #{version_ivar.name} version cannot also be the ID" %}
              {% end %}
              {% version_type = version_ivar.type.resolve %}
              {% unless version_type.stringify == "Int64" %}
                {% raise "#{entity} field #{version_ivar.name} version must be non-nil Int64, not #{version_type}" %}
              {% end %}
              {% version_default = version_ivar.default_value %}
              {% unless version_ivar.has_default_value? &&
                          version_default.is_a?(NumberLiteral) &&
                          version_default.zero? %}
                {% raise "#{entity} field #{version_ivar.name} version must default to zero" %}
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
                {% relationship = ivar.annotation(LF::Data::BelongsTo) ||
                                  ivar.annotation(LF::Data::HasOne) ||
                                  ivar.annotation(LF::Data::HasMany) %}
                {% unless (column_annotation && column_annotation[:ignore]) || relationship %}
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

          def self.__lf_id_type
            {% begin %}
              {% id_ivar = @type.instance_vars.find do |ivar|
                   column_annotation = ivar.annotation(LF::Data::Column)
                   !(column_annotation && column_annotation[:ignore]) &&
                     ivar.annotation(LF::Data::Id)
                 end %}
              {% id_annotation = id_ivar.annotation(LF::Data::Id) %}
              {% id_type = id_ivar.type.resolve %}
              {% if id_annotation[:generated] %}
                {% lookup_id_type = id_type.union_types.reject { |type| type == Nil }.first %}
              {% else %}
                {% lookup_id_type = id_type %}
              {% end %}
              {{lookup_id_type}}
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
              {% belongs_to = ivar.annotation(LF::Data::BelongsTo) %}
              {% has_one = ivar.annotation(LF::Data::HasOne) %}
              {% has_many = ivar.annotation(LF::Data::HasMany) %}
              {% if belongs_to || has_one %}
                @{{ivar.name}} = nil
              {% elsif has_many %}
                {% target_type = ivar.type.resolve.type_vars.first %}
                @{{ivar.name}} = [] of {{target_type}}
              {% elsif column_annotation && column_annotation[:ignore] %}
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
                {% relationship = ivar.annotation(LF::Data::BelongsTo) ||
                                  ivar.annotation(LF::Data::HasOne) ||
                                  ivar.annotation(LF::Data::HasMany) %}
                {% ignored = (column_annotation && column_annotation[:ignore]) || relationship %}
                {% generated_id = id_annotation && id_annotation[:generated] %}
                {% unless ignored || generated_id %}
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

          private def __lf_update_values
            {% begin %}
            {% id_ivar = @type.instance_vars.find { |ivar| ivar.annotation(LF::Data::Id) } %}
            {% id_column_annotation = id_ivar.annotation(LF::Data::Column) %}
            Tuple.new(
              {% for ivar in @type.instance_vars %}
                {% column_annotation = ivar.annotation(LF::Data::Column) %}
                {% relationship = ivar.annotation(LF::Data::BelongsTo) ||
                                  ivar.annotation(LF::Data::HasOne) ||
                                  ivar.annotation(LF::Data::HasMany) %}
                {% ignored = (column_annotation && column_annotation[:ignore]) || relationship %}
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

          def __lf_update_args
            {% if @type.instance_vars.any? { |ivar| ivar.annotation(LF::Data::Version) } %}
              {% raise "#{@type} versioned UPDATE requires an expected version" %}
            {% end %}
            __lf_update_values
          end

          def __lf_update_args(expected_version : Int64)
            {% unless @type.instance_vars.any? { |ivar| ivar.annotation(LF::Data::Version) } %}
              {% raise "#{@type} does not have a version field" %}
            {% end %}
            __lf_update_values + {expected_version}
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

          def __lf_delete_args(expected_version : Int64)
            {% begin %}
              {% version_ivar = @type.instance_vars.find { |ivar| ivar.annotation(LF::Data::Version) } %}
              {% raise "#{@type} does not have a version field" unless version_ivar %}
              __lf_delete_args + {expected_version}
            {% end %}
          end

          def self.__lf_find_args(id : T) forall T
            {% begin %}
            {% id_ivar = @type.instance_vars.find { |ivar| ivar.annotation(LF::Data::Id) } %}
            {% id_annotation = id_ivar.annotation(LF::Data::Id) %}
            {% id_type = id_ivar.type.resolve %}
            {% if id_annotation[:generated] %}
              {% lookup_id_type = id_type.union_types.reject { |type| type == Nil }.first %}
            {% else %}
              {% lookup_id_type = id_type %}
            {% end %}
            {% unless T.resolve == lookup_id_type %}
              {% raise "#{@type}.__lf_find_args expects #{lookup_id_type}, not #{T.resolve}" %}
            {% end %}
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

          def __lf_relationship_id
            {% begin %}
              {% id_ivar = @type.instance_vars.find { |ivar| ivar.annotation(LF::Data::Id) } %}
              @{{id_ivar.name}}
            {% end %}
          end

          def __lf_parent_relationships : Array(LF::Data::Internal::RelationshipTarget)
            relationships = [] of LF::Data::Internal::RelationshipTarget
            {% for ivar in @type.instance_vars %}
              {% if ivar.annotation(LF::Data::BelongsTo) %}
                if relationship = @{{ivar.name}}
                  relationships << LF::Data::Internal::TypedRelationshipTarget.new(relationship)
                end
              {% end %}
            {% end %}
            relationships
          end

          def __lf_child_relationships : Array(LF::Data::Internal::RelationshipTarget)
            relationships = [] of LF::Data::Internal::RelationshipTarget
            {% for ivar in @type.instance_vars %}
              {% if ivar.annotation(LF::Data::HasOne) %}
                if relationship = @{{ivar.name}}
                  relationships << LF::Data::Internal::TypedRelationshipTarget.new(relationship)
                end
              {% elsif ivar.annotation(LF::Data::HasMany) %}
                @{{ivar.name}}.each do |relationship|
                  relationships << LF::Data::Internal::TypedRelationshipTarget.new(relationship)
                end
              {% end %}
            {% end %}
            relationships
          end

          def __lf_cascade_persist(
            manager : LF::Data::EntityManager,
            visited : Set(UInt64),
          ) : Nil
            {% for ivar in @type.instance_vars %}
              {% relationship = ivar.annotation(LF::Data::BelongsTo) ||
                                ivar.annotation(LF::Data::HasOne) ||
                                ivar.annotation(LF::Data::HasMany) %}
              {% if relationship && relationship[:cascade_persist] %}
                {% if ivar.annotation(LF::Data::HasMany) %}
                  @{{ivar.name}}.each do |target|
                    manager.__lf_cascade_persist(
                      target,
                      visited,
                      {{@type.name.stringify}},
                      {{ivar.name.stringify}}
                    )
                  end
                {% else %}
                  if target = @{{ivar.name}}
                    manager.__lf_cascade_persist(
                      target,
                      visited,
                      {{@type.name.stringify}},
                      {{ivar.name.stringify}}
                    )
                  end
                {% end %}
              {% end %}
            {% end %}
            nil
          end

          def __lf_cascade_remove(
            manager : LF::Data::EntityManager,
            visited : Set(UInt64),
          ) : Nil
            {% for ivar in @type.instance_vars %}
              {% relationship = ivar.annotation(LF::Data::HasOne) ||
                                ivar.annotation(LF::Data::HasMany) %}
              {% if relationship && relationship[:cascade_remove] %}
                {% if ivar.annotation(LF::Data::HasMany) %}
                  @{{ivar.name}}.each do |target|
                    manager.__lf_cascade_remove(
                      target,
                      visited,
                      {{@type.name.stringify}},
                      {{ivar.name.stringify}}
                    )
                  end
                {% else %}
                  if target = @{{ivar.name}}
                    manager.__lf_cascade_remove(
                      target,
                      visited,
                      {{@type.name.stringify}},
                      {{ivar.name.stringify}}
                    )
                  end
                {% end %}
              {% end %}
            {% end %}
            nil
          end

          def __lf_sync_relationship_keys : Nil
            {% for relation_ivar in @type.instance_vars %}
              {% if relationship = relation_ivar.annotation(LF::Data::BelongsTo) %}
                {% foreign_key = relationship[:foreign_key] %}
                {% foreign_key_ivar = @type.instance_vars.find do |ivar|
                     ivar.name.stringify == foreign_key
                   end %}
                {% target_type = relation_ivar.type.resolve.union_types.reject { |type| type == Nil }.first %}
                if target = @{{relation_ivar.name}}
                  target_id = target.__lf_relationship_id
                  if target_id.nil?
                    raise LF::Data::UnsavedRelationshipError.new(
                      {{@type.name.stringify}},
                      {{relation_ivar.name.stringify}},
                      {{target_type.name.stringify}}
                    )
                  end

                  current_id = @{{foreign_key_ivar.name}}
                  if current_id.nil?
                    @{{foreign_key_ivar.name}} = target_id
                  elsif current_id != target_id
                    raise LF::Data::RelationshipKeyMismatchError.new(
                      {{@type.name.stringify}},
                      {{relation_ivar.name.stringify}},
                      {{target_type.name.stringify}},
                      {{foreign_key}},
                      current_id.inspect,
                      target_id.inspect
                    )
                  end
                end
              {% end %}
            {% end %}
            nil
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

          def __lf_version : Int64?
            {% begin %}
              {% version_ivar = @type.instance_vars.find { |ivar| ivar.annotation(LF::Data::Version) } %}
              {% if version_ivar %}
                @{{version_ivar.name}}
              {% else %}
                nil
              {% end %}
            {% end %}
          end

          def __lf_write_version(value : Int64) : Nil
            {% begin %}
              {% version_ivar = @type.instance_vars.find { |ivar| ivar.annotation(LF::Data::Version) } %}
              {% raise "#{@type} does not have a version field" unless version_ivar %}
              @{{version_ivar.name}} = value
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
