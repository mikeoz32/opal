module LF
  module Data
    module SQL
      module QueryToken
        struct OpenParen
        end

        struct CloseParen
        end

        struct And
        end

        struct Or
        end

        struct Not
        end

        struct Leaf(ExpressionType)
        end

        struct OrderLeaf(OrderingType)
        end
      end
    end
  end
end
