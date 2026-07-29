module LF
  module Data
    module Query
      struct FieldKey(Key)
      end

      struct FieldSet(EntityType)
        def resolve(key : FieldKey(Key)) forall Key
          {% begin %}
            {% matching_index = nil %}
            {% matching_count = 0 %}
            {% for ivar, index in EntityType.instance_vars %}
              {% field_key = 0_i64 %}
              {% for character in ivar.name.stringify.chars %}
                {% field_key = (field_key * 131_i64 + character.ord) % 2_147_483_647_i64 %}
              {% end %}
              {% column_annotation = ivar.annotation(LF::Data::Column) %}
              {% unless column_annotation && column_annotation[:ignore] %}
                {% if field_key == Key %}
                  {% matching_index = index %}
                  {% matching_count += 1 %}
                {% end %}
              {% end %}
            {% end %}
            {% raise "Unknown persistent field on #{EntityType}" unless matching_index %}
            {% raise "Compile-time field key collision on #{EntityType}" unless matching_count == 1 %}
            {% ivar = EntityType.instance_vars[matching_index] %}
            LF::Data::Query::Field(EntityType, {{ivar.type}}, {{matching_index}}).new
          {% end %}
        end

        macro method_missing(call)
          {% field_key = 0_i64 %}
          {% for character in call.name.stringify.chars %}
            {% field_key = (field_key * 131_i64 + character.ord) % 2_147_483_647_i64 %}
          {% end %}
          resolve(LF::Data::Query::FieldKey({{field_key}}).new)
        end
      end

      struct Field(EntityType, PropertyType, Index)
        def self.entity_type
          EntityType
        end

        def self.property_type
          PropertyType
        end

        def self.column : String
          {% begin %}
            {% ivar = EntityType.instance_vars[Index] %}
            {% column_annotation = ivar.annotation(LF::Data::Column) %}
            {{(column_annotation && column_annotation[:name]) || ivar.name.stringify}}
          {% end %}
        end

        def self.dump(value : PropertyType)
          {% begin %}
            {% ivar = EntityType.instance_vars[Index] %}
            {% column_annotation = ivar.annotation(LF::Data::Column) %}
            {% if converter = column_annotation && column_annotation[:converter] %}
              {% if PropertyType.resolve.nilable? %}
                value.nil? ? nil : LF::Data::Converter.dump(value.not_nil!, {{converter}})
              {% else %}
                LF::Data::Converter.dump(value, {{converter}})
              {% end %}
            {% else %}
              value
            {% end %}
          {% end %}
        end

        def column : String
          self.class.column
        end

        def dump(value : PropertyType)
          self.class.dump(value)
        end
      end
    end
  end
end
