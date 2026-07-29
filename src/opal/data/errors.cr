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
  end
end
