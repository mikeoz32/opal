module LF
  module Data
    abstract class MigrationLock
      abstract def acquire : Nil
      abstract def release : Nil
    end

    # SQLite coordinates through transactional DDL plus the unique migration
    # history row. This explicit strategy keeps that contract distinct from a
    # session-level database lock.
    class TransactionalHistoryMigrationLock < MigrationLock
      getter? acquired = false

      def acquire : Nil
        @acquired = true
      end

      def release : Nil
        @acquired = false
      end
    end
  end
end
