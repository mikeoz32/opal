module LF
  module Data
    class Error < Exception
    end

    class ClosedDataSourceError < Error
      getter operation : Symbol

      def initialize(@operation : Symbol)
        super("DataSource is closed: operation=#{operation}")
      end
    end

    class ClosedEntityManagerError < Error
      getter operation : Symbol

      def initialize(@operation : Symbol)
        super("EntityManager is closed: operation=#{operation}")
      end
    end

    class FailedEntityManagerError < Error
      getter operation : Symbol

      def initialize(@operation : Symbol, cause : Exception)
        super("EntityManager has failed: operation=#{operation}", cause)
      end
    end

    class MappingError < Error
      getter entity : String
      getter property : String?
      getter column : String?

      def initialize(
        @entity : String,
        @property : String?,
        @column : String?,
        cause : Exception? = nil,
      )
        context = String.build do |message|
          message << "Cannot map " << entity
          message << '#' << property if property
          message << " from column " << column.inspect if column
        end
        super(context, cause)
      end
    end

    class EntityStateError < Error
      getter operation : Symbol
      getter entity_name : String
      getter state : EntityState?

      def initialize(
        @operation : Symbol,
        @entity_name : String,
        @state : EntityState?,
      )
        super(
          "Invalid entity state: operation=#{operation}, " \
          "entity=#{entity_name}, state=#{state || "unknown"}"
        )
      end
    end

    class DetachedEntityError < EntityStateError
      def initialize(operation : Symbol, entity_name : String)
        super(operation, entity_name, EntityState::Detached)
      end
    end

    class NonUniqueResultError < Error
      getter entity_name : String
      getter rows : Int64

      def initialize(@entity_name : String, @rows : Int64)
        super("Expected at most one #{entity_name} row, got #{rows}")
      end
    end

    class InvalidQueryError < Error
      getter component : Symbol
      getter value : Int64

      def initialize(@component : Symbol, @value : Int64)
        super("Invalid query #{component}: value=#{value}")
      end
    end

    class OptimisticLockError < Error
      getter operation : Symbol
      getter entity_name : String
      getter entity_id : DB::Any
      getter expected_version : Int64

      def initialize(
        @operation : Symbol,
        @entity_name : String,
        @entity_id : DB::Any,
        @expected_version : Int64,
      )
        super(
          "Optimistic lock failed: operation=#{operation}, " \
          "entity=#{entity_name}, id=#{entity_id.inspect}, " \
          "expected_version=#{expected_version}"
        )
      end
    end

    class MigrationError < Error
      getter reason : Symbol
      getter version : Int64?
      getter migration_name : String?

      def initialize(
        @reason : Symbol,
        @version : Int64? = nil,
        @migration_name : String? = nil,
        message : String? = nil,
        cause : Exception? = nil,
      )
        super(
          message || "Invalid migration: reason=#{reason}, " \
                     "version=#{version.inspect}, name=#{migration_name.inspect}",
          cause
        )
      end
    end

    class DuplicateMigrationVersionError < MigrationError
      getter conflicting_name : String

      def initialize(version : Int64, first_name : String, @conflicting_name : String)
        super(
          :duplicate_version,
          version,
          first_name,
          "Duplicate migration version #{version}: " \
          "#{first_name.inspect} conflicts with #{conflicting_name.inspect}"
        )
      end
    end

    class MigrationOrderError < MigrationError
      getter previous_version : Int64
      getter previous_name : String

      def initialize(
        @previous_version : Int64,
        @previous_name : String,
        version : Int64,
        migration_name : String,
      )
        super(
          :not_ascending,
          version,
          migration_name,
          "Migration #{migration_name.inspect} version #{version} must be greater than " \
          "#{previous_name.inspect} version #{previous_version}"
        )
      end
    end

    class UnsupportedSchemaOperationError < Error
      getter dialect : String
      getter operation : String

      def initialize(@dialect : String, @operation : String)
        super("Dialect #{dialect.inspect} does not support schema operation #{operation.inspect}")
      end
    end
  end
end
