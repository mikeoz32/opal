module LF
  module Data
    module Query
      struct UpdateQuery(EntityType, AssignmentFields, AssignmentValues, Predicate)
        def initialize(
          @manager : EntityManager,
          @assignment_values : AssignmentValues,
          @predicate : Predicate,
        )
        end

        def self.__lf_predicate_tokens
          Predicate.__lf_tokens
        end

        def set(field : FieldType, value : ValueType) forall FieldType, ValueType
          dumped = field.dump(value)

          {% begin %}
            {% field_entity = FieldType.type_vars[0] %}
            {% unless field_entity == EntityType %}
              {% raise "#{field_entity} field belongs to #{field_entity}, not update entity #{EntityType}" %}
            {% end %}
            {% field_index = FieldType.type_vars[2] %}
            {% ivar = EntityType.instance_vars[field_index] %}
            {% if ivar.annotation(LF::Data::Id) %}
              {% raise "#{EntityType} ID field #{ivar.name} cannot be assigned by bulk UPDATE" %}
            {% end %}
            {% if ivar.annotation(LF::Data::Version) %}
              {% raise "#{EntityType} version field #{ivar.name} cannot be assigned by bulk UPDATE" %}
            {% end %}

            {% existing_index = nil %}
            {% for existing_field, index in AssignmentFields.type_vars %}
              {% existing_index = index if existing_field == FieldType %}
            {% end %}

            {% if existing_index %}
              values = Tuple.new(
                {% for _, index in AssignmentValues.type_vars %}
                  {% if index == existing_index %}
                    dumped,
                  {% else %}
                    @assignment_values[{{index}}],
                  {% end %}
                {% end %}
              )
              UpdateQuery(
                EntityType,
                AssignmentFields,
                typeof(values),
                Predicate
              ).new(@manager, values, @predicate)
            {% else %}
              values = @assignment_values + {dumped}
              UpdateQuery(
                EntityType,
                Tuple(
                  {% for existing_field in AssignmentFields.type_vars %}
                    {{existing_field}},
                  {% end %}
                  FieldType
                ),
                typeof(values),
                Predicate
              ).new(@manager, values, @predicate)
            {% end %}
          {% end %}
        end

        def where(expression : NewPredicate) forall NewPredicate
          {% if Predicate == NoPredicate %}
            UpdateQuery(
              EntityType,
              AssignmentFields,
              AssignmentValues,
              NewPredicate,
            ).new(@manager, @assignment_values, expression)
          {% else %}
            combined = @predicate.and(expression)
            UpdateQuery(
              EntityType,
              AssignmentFields,
              AssignmentValues,
              typeof(combined),
            ).new(@manager, @assignment_values, combined)
          {% end %}
        end

        def execute : Int64
          {% if AssignmentFields.type_vars.empty? %}
            {% raise "#{EntityType} bulk UPDATE requires at least one SET clause" %}
          {% end %}
          @manager.__lf_execute_bulk_update(self)
        end

        def __lf_args
          @assignment_values + @predicate.__lf_args
        end
      end
    end
  end
end
