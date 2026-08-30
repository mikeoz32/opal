module LF
  module Data
    module Query
      struct FieldKey(Key, Checksum)
      end

      struct FieldSet(EntityType)
        def resolve(key : FieldKey(Key, Checksum)) forall Key, Checksum
          {% begin %}
            {% matching_index = nil %}
            {% matching_count = 0 %}
            {% for ivar, index in EntityType.instance_vars %}
              {% field_key = 0_i64 %}
              {% checksum = 0_i64 %}
              {% for character in ivar.name.stringify.chars %}
                {% field_key = (field_key * 131_i64 + character.ord) % 2_147_483_647_i64 %}
                {% checksum = (checksum * 137_i64 + character.ord) % 2_147_483_647_i64 %}
              {% end %}
              {% column_annotation = ivar.annotation(LF::Data::Column) %}
              {% relationship = ivar.annotation(LF::Data::BelongsTo) ||
                                ivar.annotation(LF::Data::HasOne) ||
                                ivar.annotation(LF::Data::HasMany) %}
              {% unless (column_annotation && column_annotation[:ignore]) || relationship %}
                {% if field_key == Key && checksum == Checksum %}
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
          {% checksum = 0_i64 %}
          {% for character in call.name.stringify.chars %}
            {% field_key = (field_key * 131_i64 + character.ord) % 2_147_483_647_i64 %}
            {% checksum = (checksum * 137_i64 + character.ord) % 2_147_483_647_i64 %}
          {% end %}
          resolve(LF::Data::Query::FieldKey({{field_key}}, {{checksum}}).new)
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

        def eq(value : PropertyType)
          {% if PropertyType.resolve.nilable? %}
            raise InvalidPredicateError.new(:eq, column, "nilable runtime values must use eq(nil) or is_nil") if value.nil?
          {% end %}
          dumped = dump(value)
          Eq(typeof(self), typeof(dumped)).new(dumped)
        end

        def eq(value : Nil)
          {% unless PropertyType.resolve.nilable? %}
            {% raise "#{EntityType} field #{EntityType.instance_vars[Index].name} does not support a nil predicate" %}
          {% end %}
          IsNil(typeof(self)).new
        end

        def ne(value : PropertyType)
          {% if PropertyType.resolve.nilable? %}
            raise InvalidPredicateError.new(:ne, column, "nilable runtime values must use ne(nil) or is_not_nil") if value.nil?
          {% end %}
          dumped = dump(value)
          Ne(typeof(self), typeof(dumped)).new(dumped)
        end

        def ne(value : Nil)
          {% unless PropertyType.resolve.nilable? %}
            {% raise "#{EntityType} field #{EntityType.instance_vars[Index].name} does not support a nil predicate" %}
          {% end %}
          IsNotNil(typeof(self)).new
        end

        def lt(value : PropertyType)
          ensure_ordered
          {% if PropertyType.resolve.nilable? %}
            raise InvalidPredicateError.new(:lt, column, "NULL ordering is not supported") if value.nil?
          {% end %}
          dumped = dump(value)
          Lt(typeof(self), typeof(dumped)).new(dumped)
        end

        def lt(value : Nil)
          {% raise "#{EntityType} field #{EntityType.instance_vars[Index].name} does not support NULL ordering" %}
        end

        def lte(value : PropertyType)
          ensure_ordered
          {% if PropertyType.resolve.nilable? %}
            raise InvalidPredicateError.new(:lte, column, "NULL ordering is not supported") if value.nil?
          {% end %}
          dumped = dump(value)
          Lte(typeof(self), typeof(dumped)).new(dumped)
        end

        def lte(value : Nil)
          {% raise "#{EntityType} field #{EntityType.instance_vars[Index].name} does not support NULL ordering" %}
        end

        def gt(value : PropertyType)
          ensure_ordered
          {% if PropertyType.resolve.nilable? %}
            raise InvalidPredicateError.new(:gt, column, "NULL ordering is not supported") if value.nil?
          {% end %}
          dumped = dump(value)
          Gt(typeof(self), typeof(dumped)).new(dumped)
        end

        def gt(value : Nil)
          {% raise "#{EntityType} field #{EntityType.instance_vars[Index].name} does not support NULL ordering" %}
        end

        def gte(value : PropertyType)
          ensure_ordered
          {% if PropertyType.resolve.nilable? %}
            raise InvalidPredicateError.new(:gte, column, "NULL ordering is not supported") if value.nil?
          {% end %}
          dumped = dump(value)
          Gte(typeof(self), typeof(dumped)).new(dumped)
        end

        def gte(value : Nil)
          {% raise "#{EntityType} field #{EntityType.instance_vars[Index].name} does not support NULL ordering" %}
        end

        def in(values : Tuple(*ValueTypes)) forall ValueTypes
          {% begin %}
            {% for value_type in ValueTypes %}
              {% if value_type == Nil || value_type.resolve.nilable? %}
                {% raise "#{EntityType} field #{EntityType.instance_vars[Index].name} does not support NULL values in IN" %}
              {% end %}
            {% end %}
            dumped = Tuple.new(
              {% for index in 0...ValueTypes.size %}
                dump(values[{{index}}]),
              {% end %}
            )
            In(typeof(self), typeof(dumped)).new(dumped)
          {% end %}
        end

        def in(values : Array(ValueType)) forall ValueType
          dumped = [] of DB::Any
          values.each do |value|
            raise InvalidPredicateError.new(:in, column, "NULL values are not supported") if value.nil?
            dumped << dump(value).as(DB::Any)
          end
          DynamicIn(typeof(self)).new(dumped)
        end

        def is_nil
          {% unless PropertyType.resolve.nilable? %}
            {% raise "#{EntityType} field #{EntityType.instance_vars[Index].name} does not support a nil predicate" %}
          {% end %}
          IsNil(typeof(self)).new
        end

        def is_not_nil
          {% unless PropertyType.resolve.nilable? %}
            {% raise "#{EntityType} field #{EntityType.instance_vars[Index].name} does not support a nil predicate" %}
          {% end %}
          IsNotNil(typeof(self)).new
        end

        def like(value : String)
          {% begin %}
            {% non_nil_types = PropertyType.resolve.union_types.reject { |type| type == Nil } %}
            {% unless non_nil_types.size == 1 && non_nil_types.first.stringify == "String" %}
              {% raise "#{EntityType} field #{EntityType.instance_vars[Index].name} does not support LIKE" %}
            {% end %}
            dumped = dump(value)
            Like(typeof(self), typeof(dumped)).new(dumped)
          {% end %}
        end

        def asc
          Ordering(typeof(self), Asc).new
        end

        def desc
          Ordering(typeof(self), Desc).new
        end

        private def ensure_ordered : Nil
          {% begin %}
            {% non_nil_types = PropertyType.resolve.union_types.reject { |type| type == Nil } %}
            {% ordered = ["Int32", "Int64", "Float32", "Float64", "String", "Time"] %}
            {% unless non_nil_types.size == 1 && ordered.includes?(non_nil_types.first.stringify) %}
              {% raise "#{EntityType} field #{EntityType.instance_vars[Index].name} is not orderable" %}
            {% end %}
          {% end %}
        end
      end
    end
  end
end
