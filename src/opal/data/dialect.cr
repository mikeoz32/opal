module LF
  module Data
    abstract class Dialect
      abstract def name : String
      abstract def quote_identifier(identifier : String) : String
      abstract def placeholder(position : Int32) : String

      abstract def find_plan(entity : T.class) : SQL::StatementPlan forall T
      abstract def insert_plan(entity : T.class) : SQL::InsertPlan forall T
      abstract def update_plan(entity : T.class) : SQL::StatementPlan forall T
      abstract def delete_plan(entity : T.class) : SQL::StatementPlan forall T
      abstract def select_plan(entity : T.class, shape : S.class) : SQL::StatementPlan forall T, S

      def offset_without_limit(placeholder : String) : String
        "OFFSET #{placeholder}"
      end

      abstract def supports?(capability : DialectCapability) : Bool
    end
  end
end
