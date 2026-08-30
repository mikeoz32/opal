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

    class InvalidPredicateError < Error
      getter operation : Symbol
      getter field : String

      def initialize(@operation : Symbol, @field : String, reason : String)
        super("Invalid predicate: operation=#{operation}, field=#{field.inspect}, #{reason}")
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

    class MigrationHistoryMismatchError < MigrationError
      getter expected_name : String
      getter applied_name : String

      def initialize(
        version : Int64,
        @expected_name : String,
        @applied_name : String,
      )
        super(
          :history_mismatch,
          version,
          expected_name,
          "Migration version #{version} is named #{expected_name.inspect}, " \
          "but history contains #{applied_name.inspect}"
        )
      end
    end

    class UnknownAppliedMigrationError < MigrationError
      getter applied_name : String

      def initialize(@version : Int64, @applied_name : String)
        super(
          :unknown_applied_version,
          version,
          nil,
          "Database contains applied migration version #{version} " \
          "(#{applied_name.inspect}) which is absent from the current migration set"
        )
      end
    end

    class UnsupportedMigrationCapabilityError < MigrationError
      getter dialect : String
      getter capability : DialectCapability

      def initialize(
        @dialect : String,
        @capability : DialectCapability,
        version : Int64? = nil,
        migration_name : String? = nil,
      )
        super(
          :unsupported_capability,
          version,
          migration_name,
          "Dialect #{dialect.inspect} does not support migration capability " \
          "#{capability}"
        )
      end
    end

    class MigrationLockConfigurationError < MigrationError
      getter namespace : String
      getter timeout : Time::Span

      def initialize(@namespace : String, @timeout : Time::Span, reason : String)
        super(
          :invalid_lock_configuration,
          message: "Invalid migration lock configuration: #{reason}"
        )
      end
    end

    class MigrationLockTimeoutError < MigrationError
      getter dialect : String
      getter namespace : String
      getter timeout : Time::Span

      def initialize(
        @dialect : String,
        @namespace : String,
        @timeout : Time::Span,
      )
        super(
          :lock_timeout,
          message: "Timed out acquiring #{dialect.inspect} migration lock " \
                   "for namespace #{namespace.inspect} after #{timeout}"
        )
      end
    end

    class MigrationLockReleaseError < MigrationError
      getter dialect : String
      getter namespace : String

      def initialize(@dialect : String, @namespace : String)
        super(
          :lock_release_failed,
          message: "Dialect #{dialect.inspect} did not release migration lock " \
                   "for namespace #{namespace.inspect}"
        )
      end
    end

    class MigrationLockCleanupError < MigrationError
      getter primary_error : Exception
      getter cleanup_error : Exception

      def initialize(@primary_error : Exception, @cleanup_error : Exception)
        super(
          :lock_cleanup_failed,
          message: "Migration failed and migration lock cleanup also failed",
          cause: primary_error
        )
      end
    end

    class ForeignKeySetupError < Error
      getter dialect : String
      getter value : Int64

      def initialize(@dialect : String, @value : Int64)
        super(
          "Dialect #{dialect.inspect} failed to enable foreign-key enforcement: " \
          "PRAGMA foreign_keys=#{value}"
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

    class SchemaInspectionError < Error
      getter dialect : String

      def initialize(@dialect : String, message : String, cause : Exception? = nil)
        super("Cannot inspect #{dialect.inspect} schema: #{message}", cause)
      end
    end

    class UnsupportedSchemaInspectionError < SchemaInspectionError
      def initialize(dialect : String)
        super(dialect, "dialect does not provide schema introspection")
      end
    end

    class UnsafeSchemaChangeError < Error
      getter changes : Array(String)

      def initialize(@changes : Array(String))
        super(
          "Schema diff contains destructive changes; pass allow_destructive: true " \
          "after review: #{changes.join(", ")}"
        )
      end
    end

    class UnresolvedSchemaDiffError < Error
      getter diagnostics : Array(Schema::DiffDiagnostic)

      def initialize(@diagnostics : Array(Schema::DiffDiagnostic))
        super(
          "Schema diff requires explicit migration decisions: " \
          "#{diagnostics.map(&.message).join("; ")}"
        )
      end
    end

    class EmptySchemaDiffError < Error
      def initialize
        super("Schema diff is empty; no migration source was generated")
      end
    end

    class MigrationSourceGenerationError < Error
      def initialize(reason : String)
        super("Cannot generate migration source: #{reason}")
      end
    end
  end
end
