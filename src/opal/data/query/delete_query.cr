module LF
  module Data
    module Query
      struct DeleteQuery(EntityType, Predicate)
        def initialize(
          @manager : EntityManager,
          @predicate : Predicate,
        )
        end

        def self.__lf_predicate_tokens
          Predicate.__lf_tokens
        end

        def where(expression : NewPredicate) forall NewPredicate
          {% if Predicate == NoPredicate %}
            DeleteQuery(EntityType, NewPredicate).new(@manager, expression)
          {% else %}
            combined = @predicate.and(expression)
            DeleteQuery(EntityType, typeof(combined)).new(@manager, combined)
          {% end %}
        end

        def execute : Int64
          @manager.__lf_execute_bulk_delete(self)
        end

        def __lf_args
          @predicate.__lf_args
        end
      end
    end
  end
end
