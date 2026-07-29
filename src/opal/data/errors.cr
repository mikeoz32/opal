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
  end
end
