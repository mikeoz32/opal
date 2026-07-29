module LF
  module Data
    module Hydrator
      extend self

      def validate_columns(
        result : DB::ResultSet,
        entity : String,
        expected : Tuple,
      ) : Nil
        expected.each_with_index do |column, index|
          actual = index < result.column_count ? result.column_name(index) : nil
          next if actual == column

          raise MappingError.new(entity, nil, actual || column)
        end

        if result.column_count > expected.size
          raise MappingError.new(entity, nil, result.column_name(expected.size))
        end
      end
    end
  end
end
