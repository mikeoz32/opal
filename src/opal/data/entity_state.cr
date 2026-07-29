module LF
  module Data
    enum EntityState
      New
      Managed
      Removed
      Detached
    end

    module Internal
      enum EntityOperation
        Insert
        Update
        Delete
      end

      abstract class TrackedEntity
        property state : EntityState
        property operation : EntityOperation?
        property sequence : Int64?
        property database_id : DB::Any
        property? has_database_id : Bool
        property loaded_version : Int64?

        def initialize(
          @state : EntityState,
          @database_id : DB::Any = nil,
          @has_database_id : Bool = false,
          @loaded_version : Int64? = nil,
        )
          @operation = nil
          @sequence = nil
        end

        abstract def reference : Reference
        abstract def entity_name : String
        abstract def execute(manager : EntityManager, operation : EntityOperation) : Nil
      end

      class TypedTrackedEntity(T) < TrackedEntity
        getter entity : T

        def initialize(
          @entity : T,
          state : EntityState,
          database_id : DB::Any = nil,
          has_database_id : Bool = false,
          loaded_version : Int64? = nil,
        )
          super(state, database_id, has_database_id, loaded_version)
        end

        def reference : Reference
          @entity
        end

        def entity_name : String
          T.name
        end

        def execute(manager : EntityManager, operation : EntityOperation) : Nil
          case operation
          when EntityOperation::Insert
            manager.__lf_execute_insert(@entity, self)
          when EntityOperation::Update
            manager.__lf_execute_update(@entity, self)
          when EntityOperation::Delete
            manager.__lf_execute_delete(@entity, self)
          end
        end
      end
    end
  end
end
