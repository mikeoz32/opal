module LF
  module Data
    module Query
      struct SelectQuery(EntityType, Predicate, Orders, LimitState, OffsetState)
        getter manager : EntityManager
        getter predicate : Predicate
        getter limit_value : Int64?
        getter offset_value : Int64?

        def initialize(
          @manager : EntityManager,
          @predicate : Predicate,
          @limit_value : Int64? = nil,
          @offset_value : Int64? = nil,
        )
        end

        def self.__lf_predicate_tokens
          Predicate.__lf_tokens
        end

        def self.__lf_order_tokens
          Orders.__lf_tokens
        end

        def where(expression : NewPredicate) forall NewPredicate
          {% if Predicate == NoPredicate %}
            SelectQuery(
              EntityType,
              NewPredicate,
              Orders,
              LimitState,
              OffsetState,
            ).new(
              @manager,
              expression,
              @limit_value,
              @offset_value
            )
          {% else %}
            combined = @predicate.and(expression)
            SelectQuery(
              EntityType,
              typeof(combined),
              Orders,
              LimitState,
              OffsetState,
            ).new(
              @manager,
              combined,
              @limit_value,
              @offset_value
            )
          {% end %}
        end

        def order_by(ordering : NewOrdering) forall NewOrdering
          SelectQuery(
            EntityType,
            Predicate,
            OrderList(Orders, NewOrdering),
            LimitState,
            OffsetState,
          ).new(
            @manager,
            @predicate,
            @limit_value,
            @offset_value
          )
        end

        def limit(value : Int)
          raise InvalidQueryError.new(:limit, value.to_i64) if value < 0

          SelectQuery(
            EntityType,
            Predicate,
            Orders,
            WithLimit,
            OffsetState,
          ).new(
            @manager,
            @predicate,
            value.to_i64,
            @offset_value
          )
        end

        def offset(value : Int)
          raise InvalidQueryError.new(:offset, value.to_i64) if value < 0

          SelectQuery(
            EntityType,
            Predicate,
            Orders,
            LimitState,
            WithOffset,
          ).new(
            @manager,
            @predicate,
            @limit_value,
            value.to_i64
          )
        end

        def to_a : Array(EntityType)
          @manager.__lf_select_to_a(self)
        end

        def first? : EntityType?
          @manager.__lf_select_first(self)
        end

        def count : Int64
          @manager.__lf_select_count(self)
        end

        def exists? : Bool
          @manager.__lf_select_exists(self)
        end

        def __lf_predicate_args
          @predicate.__lf_args
        end

        def __lf_rows_args
          {% begin %}
            arguments = @predicate.__lf_args
            {% if LimitState == WithLimit %}
              arguments += {@limit_value.not_nil!}
            {% end %}
            {% if OffsetState == WithOffset %}
              arguments += {@offset_value.not_nil!}
            {% end %}
            arguments
          {% end %}
        end

        def __lf_first_args
          {% begin %}
            arguments = @predicate.__lf_args
            {% if OffsetState == WithOffset %}
              arguments += {@offset_value.not_nil!}
            {% end %}
            arguments
          {% end %}
        end
      end
    end
  end
end
