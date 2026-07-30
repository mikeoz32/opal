module LF
  module Data
    module Query
      enum DynamicTerminal
        Rows
        First
        Count
        Exists
      end

      abstract class DynamicPredicateNode(EntityType)
        abstract def render(renderer : DynamicRenderer(EntityType)) : String
      end

      class TypedDynamicPredicateNode(EntityType, ExpressionType) < DynamicPredicateNode(EntityType)
        def initialize(@expression : ExpressionType)
        end

        def render(renderer : DynamicRenderer(EntityType)) : String
          renderer.render(@expression)
        end
      end

      abstract class DynamicOrderNode(EntityType)
        abstract def render(renderer : DynamicRenderer(EntityType)) : String
      end

      class TypedDynamicOrderNode(EntityType, OrderingType) < DynamicOrderNode(EntityType)
        def initialize(@ordering : OrderingType)
        end

        def render(renderer : DynamicRenderer(EntityType)) : String
          renderer.render_order(@ordering)
        end
      end

      class DynamicRenderer(EntityType)
        @arguments = [] of DB::Any
        @placeholder_position = 1

        def initialize(@dialect : Dialect)
        end

        def build(
          predicates : Array(DynamicPredicateNode(EntityType)),
          orders : Array(DynamicOrderNode(EntityType)),
          limit : Int64?,
          offset : Int64?,
          terminal : DynamicTerminal,
        ) : RenderedQuery
          table = @dialect.quote_identifier(EntityType.__lf_table_name)
          sql = case terminal
                when .count?
                  "SELECT COUNT(*) FROM #{table}"
                when .exists?
                  "SELECT 1 FROM #{table}"
                else
                  columns = EntityType.__lf_persistent_columns.map do |column|
                    @dialect.quote_identifier(column)
                  end.join(", ")
                  "SELECT #{columns} FROM #{table}"
                end

          unless predicates.empty?
            fragments = predicates.map { |node| "(#{node.render(self)})" }
            sql += " WHERE " + fragments.join(" AND ")
          end

          unless terminal.count? || terminal.exists? || orders.empty?
            order_fragments = orders.map { |node| node.render(self).as(String) }
            sql += " ORDER BY " + order_fragments.join(", ")
          end

          case terminal
          when .exists?
            sql += " LIMIT 1"
          when .first?
            sql += " LIMIT 1"
            if offset
              sql += " OFFSET " + bind(offset)
            end
          when .rows?
            if limit
              sql += " LIMIT " + bind(limit)
              sql += " OFFSET " + bind(offset) if offset
            elsif offset
              sql += " " + @dialect.offset_without_limit(bind(offset))
            end
          end

          RenderedQuery.new(sql, @arguments)
        end

        def render(expression : Eq(FieldType, StoredType)) : String forall FieldType, StoredType
          "#{column(FieldType)} = #{bind(expression.value)}"
        end

        def render(expression : Ne(FieldType, StoredType)) : String forall FieldType, StoredType
          "#{column(FieldType)} <> #{bind(expression.value)}"
        end

        def render(expression : Lt(FieldType, StoredType)) : String forall FieldType, StoredType
          "#{column(FieldType)} < #{bind(expression.value)}"
        end

        def render(expression : Lte(FieldType, StoredType)) : String forall FieldType, StoredType
          "#{column(FieldType)} <= #{bind(expression.value)}"
        end

        def render(expression : Gt(FieldType, StoredType)) : String forall FieldType, StoredType
          "#{column(FieldType)} > #{bind(expression.value)}"
        end

        def render(expression : Gte(FieldType, StoredType)) : String forall FieldType, StoredType
          "#{column(FieldType)} >= #{bind(expression.value)}"
        end

        def render(expression : Like(FieldType, StoredType)) : String forall FieldType, StoredType
          "#{column(FieldType)} LIKE #{bind(expression.value)}"
        end

        def render(expression : In(FieldType, StoredValues)) : String forall FieldType, StoredValues
          return "0 = 1" if expression.values.empty?

          placeholders = expression.values.map { |value| bind(value) }
          "#{column(FieldType)} IN (#{placeholders.join(", ")})"
        end

        def render(expression : DynamicIn(FieldType)) : String forall FieldType
          return "0 = 1" if expression.values.empty?

          placeholders = expression.values.map { |value| bind(value) }
          "#{column(FieldType)} IN (#{placeholders.join(", ")})"
        end

        def render(expression : IsNil(FieldType)) : String forall FieldType
          "#{column(FieldType)} IS NULL"
        end

        def render(expression : IsNotNil(FieldType)) : String forall FieldType
          "#{column(FieldType)} IS NOT NULL"
        end

        def render(expression : And(Left, Right)) : String forall Left, Right
          "(#{render(expression.left)}) AND (#{render(expression.right)})"
        end

        def render(expression : Or(Left, Right)) : String forall Left, Right
          "(#{render(expression.left)}) OR (#{render(expression.right)})"
        end

        def render(expression : Not(Child)) : String forall Child
          "NOT (#{render(expression.child)})"
        end

        def render_order(ordering : Ordering(FieldType, Direction)) : String forall FieldType, Direction
          direction = {% if Direction == Asc %} "ASC" {% else %} "DESC" {% end %}
          "#{column(FieldType)} #{direction}"
        end

        private def column(field : FieldType.class) : String forall FieldType
          {% begin %}
            {% field_entity = FieldType.type_vars[0] %}
            {% unless field_entity == EntityType %}
              {% raise "#{field_entity} field belongs to #{field_entity}, not query entity #{EntityType}" %}
            {% end %}
          {% end %}
          @dialect.quote_identifier(FieldType.column)
        end

        private def bind(value) : String
          @arguments << value.as(DB::Any)
          position = @placeholder_position
          @placeholder_position += 1
          @dialect.placeholder(position)
        end
      end
    end
  end
end
