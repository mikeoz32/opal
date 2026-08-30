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

      abstract class RelationshipTarget
        abstract def reference : Reference
      end

      class TypedRelationshipTarget(T) < RelationshipTarget
        def initialize(@reference : T)
        end

        def reference : Reference
          @reference
        end
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
        abstract def parent_relationships : Array(RelationshipTarget)
        abstract def child_relationships : Array(RelationshipTarget)
        abstract def sync_relationship_keys : Nil
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

        def parent_relationships : Array(RelationshipTarget)
          @entity.__lf_parent_relationships
        end

        def child_relationships : Array(RelationshipTarget)
          @entity.__lf_child_relationships
        end

        def sync_relationship_keys : Nil
          @entity.__lf_sync_relationship_keys
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
