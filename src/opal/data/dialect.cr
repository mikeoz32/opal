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
      abstract def update_query_plan(entity : T.class, shape : S.class) : SQL::StatementPlan forall T, S
      abstract def delete_query_plan(entity : T.class, shape : S.class) : SQL::StatementPlan forall T, S

      def offset_without_limit(placeholder : String) : String
        "OFFSET #{placeholder}"
      end

      def setup_connection(connection : DB::Connection) : Nil
      end

      def schema_renderer(connection : DB::Connection) : SchemaRenderer
        raise UnsupportedSchemaOperationError.new(name, "schema migrations")
      end

      def schema_introspector(connection : DB::Connection) : Schema::Introspector
        raise UnsupportedSchemaInspectionError.new(name)
      end

      def schema_type_matches?(
        desired : Schema::ColumnType,
        actual : Schema::ColumnType,
      ) : Bool
        desired == actual
      end

      def schema_default_matches?(
        desired : Schema::DefaultValue?,
        actual : Schema::ColumnSnapshot,
      ) : Bool
        return !actual.has_default? unless desired
        return false unless inspected = actual.default

        schema_literal_matches?(desired.value, inspected.value)
      end

      def migration_lock(
        connection : DB::Connection,
        namespace : String,
        timeout : Time::Span,
      ) : MigrationLock
        raise UnsupportedMigrationCapabilityError.new(
          name,
          DialectCapability::MigrationLock
        )
      end

      def migration_history_record_conflict?(
        error : Exception,
        table : String,
        column : String,
      ) : Bool
        false
      end

      abstract def supports?(capability : DialectCapability) : Bool

      private def schema_literal_matches?(
        desired : Schema::Literal,
        actual : Schema::Literal,
      ) : Bool
        case desired
        when Int32, Int64
          case actual
          when Int32, Int64
            desired.to_i64 == actual.to_i64
          else
            false
          end
        else
          desired == actual
        end
      end
    end
  end
end
