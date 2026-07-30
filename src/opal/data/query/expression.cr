module LF
  module Data
    module Query
      module Expression
        def and(other : Other) forall Other
          And(typeof(self), Other).new(self, other)
        end

        def or(other : Other) forall Other
          Or(typeof(self), Other).new(self, other)
        end

        def not
          Not(typeof(self)).new(self)
        end
      end

      struct Eq(FieldType, StoredType)
        include Expression

        getter value : StoredType

        def initialize(@value : StoredType)
        end

        def __lf_args
          {@value}
        end

        def self.__lf_tokens
          {LF::Data::SQL::QueryToken::Leaf(Eq(FieldType, StoredType)).new}
        end
      end

      struct Ne(FieldType, StoredType)
        include Expression

        getter value : StoredType

        def initialize(@value : StoredType)
        end

        def __lf_args
          {@value}
        end

        def self.__lf_tokens
          {LF::Data::SQL::QueryToken::Leaf(Ne(FieldType, StoredType)).new}
        end
      end

      struct Lt(FieldType, StoredType)
        include Expression

        getter value : StoredType

        def initialize(@value : StoredType)
        end

        def __lf_args
          {@value}
        end

        def self.__lf_tokens
          {LF::Data::SQL::QueryToken::Leaf(Lt(FieldType, StoredType)).new}
        end
      end

      struct Lte(FieldType, StoredType)
        include Expression

        getter value : StoredType

        def initialize(@value : StoredType)
        end

        def __lf_args
          {@value}
        end

        def self.__lf_tokens
          {LF::Data::SQL::QueryToken::Leaf(Lte(FieldType, StoredType)).new}
        end
      end

      struct Gt(FieldType, StoredType)
        include Expression

        getter value : StoredType

        def initialize(@value : StoredType)
        end

        def __lf_args
          {@value}
        end

        def self.__lf_tokens
          {LF::Data::SQL::QueryToken::Leaf(Gt(FieldType, StoredType)).new}
        end
      end

      struct Gte(FieldType, StoredType)
        include Expression

        getter value : StoredType

        def initialize(@value : StoredType)
        end

        def __lf_args
          {@value}
        end

        def self.__lf_tokens
          {LF::Data::SQL::QueryToken::Leaf(Gte(FieldType, StoredType)).new}
        end
      end

      struct Like(FieldType, StoredType)
        include Expression

        getter value : StoredType

        def initialize(@value : StoredType)
        end

        def __lf_args
          {@value}
        end

        def self.__lf_tokens
          {LF::Data::SQL::QueryToken::Leaf(Like(FieldType, StoredType)).new}
        end
      end

      struct In(FieldType, StoredValues)
        include Expression

        getter values : StoredValues

        def initialize(@values : StoredValues)
        end

        def __lf_args
          @values
        end

        def self.__lf_tokens
          {LF::Data::SQL::QueryToken::Leaf(In(FieldType, StoredValues)).new}
        end
      end

      struct IsNil(FieldType)
        include Expression

        def __lf_args
          Tuple.new
        end

        def self.__lf_tokens
          {LF::Data::SQL::QueryToken::Leaf(IsNil(FieldType)).new}
        end
      end

      struct IsNotNil(FieldType)
        include Expression

        def __lf_args
          Tuple.new
        end

        def self.__lf_tokens
          {LF::Data::SQL::QueryToken::Leaf(IsNotNil(FieldType)).new}
        end
      end

      struct And(Left, Right)
        include Expression

        getter left : Left
        getter right : Right

        def initialize(@left : Left, @right : Right)
        end

        def __lf_args
          @left.__lf_args + @right.__lf_args
        end

        def self.__lf_tokens
          {LF::Data::SQL::QueryToken::OpenParen.new} +
            Left.__lf_tokens +
            {
              LF::Data::SQL::QueryToken::CloseParen.new,
              LF::Data::SQL::QueryToken::And.new,
              LF::Data::SQL::QueryToken::OpenParen.new,
            } +
            Right.__lf_tokens +
            {LF::Data::SQL::QueryToken::CloseParen.new}
        end
      end

      struct Or(Left, Right)
        include Expression

        getter left : Left
        getter right : Right

        def initialize(@left : Left, @right : Right)
        end

        def __lf_args
          @left.__lf_args + @right.__lf_args
        end

        def self.__lf_tokens
          {LF::Data::SQL::QueryToken::OpenParen.new} +
            Left.__lf_tokens +
            {
              LF::Data::SQL::QueryToken::CloseParen.new,
              LF::Data::SQL::QueryToken::Or.new,
              LF::Data::SQL::QueryToken::OpenParen.new,
            } +
            Right.__lf_tokens +
            {LF::Data::SQL::QueryToken::CloseParen.new}
        end
      end

      struct Not(Child)
        include Expression

        getter child : Child

        def initialize(@child : Child)
        end

        def __lf_args
          @child.__lf_args
        end

        def self.__lf_tokens
          {
            LF::Data::SQL::QueryToken::Not.new,
            LF::Data::SQL::QueryToken::OpenParen.new,
          } +
            Child.__lf_tokens +
            {LF::Data::SQL::QueryToken::CloseParen.new}
        end
      end
    end
  end
end
