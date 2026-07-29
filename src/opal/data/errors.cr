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
  end
end
