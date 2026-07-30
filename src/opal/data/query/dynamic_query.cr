module LF
  module Data
    module Query
      class DynamicQuery(EntityType)
        @predicates = [] of DynamicPredicateNode(EntityType)
        @orders = [] of DynamicOrderNode(EntityType)
        @limit : Int64?
        @offset : Int64?

        def initialize(@manager : EntityManager)
        end

        def where(expression : ExpressionType) : self forall ExpressionType
          @predicates << TypedDynamicPredicateNode(EntityType, ExpressionType).new(expression)
          self
        end

        def order_by(ordering : OrderingType) : self forall OrderingType
          @orders << TypedDynamicOrderNode(EntityType, OrderingType).new(ordering)
          self
        end

        def limit(value : Int) : self
          raise InvalidQueryError.new(:limit, value.to_i64) if value < 0

          @limit = value.to_i64
          self
        end

        def offset(value : Int) : self
          raise InvalidQueryError.new(:offset, value.to_i64) if value < 0

          @offset = value.to_i64
          self
        end

        def to_a : Array(EntityType)
          @manager.__lf_dynamic_select_to_a(self)
        end

        def first? : EntityType?
          @manager.__lf_dynamic_select_first(self)
        end

        def count : Int64
          @manager.__lf_dynamic_select_count(self)
        end

        def exists? : Bool
          @manager.__lf_dynamic_select_exists(self)
        end

        def __lf_render(dialect : Dialect, terminal : DynamicTerminal) : RenderedQuery
          DynamicRenderer(EntityType).new(dialect).build(
            @predicates,
            @orders,
            @limit,
            @offset,
            terminal
          )
        end
      end
    end
  end
end
