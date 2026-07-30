module LF
  module Data
    module Query
      struct NoPredicate
        def __lf_args
          Tuple.new
        end

        def self.__lf_tokens
          Tuple.new
        end
      end

      struct NoOrdering
        def self.__lf_tokens
          Tuple.new
        end
      end

      struct OrderList(Previous, Current)
        def self.__lf_tokens
          Previous.__lf_tokens + {
            LF::Data::SQL::QueryToken::OrderLeaf(Current).new,
          }
        end
      end

      struct Asc
      end

      struct Desc
      end

      struct Ordering(FieldType, Direction)
      end

      struct NoLimit
      end

      struct WithLimit
      end

      struct NoOffset
      end

      struct WithOffset
      end

      struct Rows(QueryShape)
        def self.__lf_predicate_tokens
          QueryShape.__lf_predicate_tokens
        end

        def self.__lf_order_tokens
          QueryShape.__lf_order_tokens
        end
      end

      struct First(QueryShape)
        def self.__lf_predicate_tokens
          QueryShape.__lf_predicate_tokens
        end

        def self.__lf_order_tokens
          QueryShape.__lf_order_tokens
        end
      end

      struct Count(QueryShape)
        def self.__lf_predicate_tokens
          QueryShape.__lf_predicate_tokens
        end

        def self.__lf_order_tokens
          QueryShape.__lf_order_tokens
        end
      end

      struct Exists(QueryShape)
        def self.__lf_predicate_tokens
          QueryShape.__lf_predicate_tokens
        end

        def self.__lf_order_tokens
          QueryShape.__lf_order_tokens
        end
      end
    end
  end
end
