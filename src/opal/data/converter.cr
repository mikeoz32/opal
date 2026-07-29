module LF
  module Data
    module Converter
      extend self

      def load(result : DB::ResultSet, converter : C.class, type : T.class) : T forall C, T
        converter.load(result).as(T)
      end

      def dump(value : Nil, converter : C.class) : Nil forall C
        nil
      end

      def dump(value : T, converter : C.class) forall C, T
        converter.dump(value)
      end
    end
  end
end
