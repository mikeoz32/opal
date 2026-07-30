module LF
  module Data
    class EntityManager
      getter? closed = false

      @failure : Exception?

      def initialize(
        @connection : DB::Connection,
        @dialect : Dialect,
        @dispatcher : Internal::ListenerDispatcher,
      )
        @entries_by_object = {} of UInt64 => Internal::TrackedEntity
        @entries_by_identity = {} of Internal::EntityKey => Internal::TrackedEntity
        @operation_queue = Internal::OperationQueue.new
        @next_sequence = 0_i64
      end

      def persist(entity : T) : Nil forall T
        ensure_available(:persist)

        if entry = @entries_by_object[entity.object_id]?
          case entry.state
          when EntityState::New
            schedule(entry, Internal::EntityOperation::Insert)
          when EntityState::Managed
            schedule(entry, Internal::EntityOperation::Update)
          when EntityState::Removed
            raise EntityStateError.new(:persist, entry.entity_name, entry.state)
          when EntityState::Detached
            raise DetachedEntityError.new(:persist, entry.entity_name)
          end
        else
          entry = Internal::TypedTrackedEntity(T).new(entity, EntityState::New)
          @entries_by_object[entity.object_id] = entry
          schedule(entry, Internal::EntityOperation::Insert)
        end
      end

      def remove(entity : T) : Nil forall T
        ensure_available(:remove)

        entry = @entries_by_object[entity.object_id]?
        unless entry
          raise EntityStateError.new(:remove, T.name, nil)
        end

        case entry.state
        when EntityState::New
          @operation_queue.cancel(entry)
          entry.state = EntityState::Detached
        when EntityState::Managed
          entry.state = EntityState::Removed
          schedule(entry, Internal::EntityOperation::Delete)
        when EntityState::Removed
          nil
        when EntityState::Detached
          raise DetachedEntityError.new(:remove, entry.entity_name)
        end
      end

      def find(entity : T.class, id) : T? forall T
        ensure_available(:find)

        arguments = T.__lf_find_args(id)
        database_id = arguments[0].as(DB::Any)
        key = Internal::EntityKey.new(T.name, database_id)
        if entry = @entries_by_identity[key]?
          return entry.as(Internal::TypedTrackedEntity(T)).entity
        end

        plan = @dialect.find_plan(T)
        observed = !@dispatcher.empty?
        started_at = Time.instant if observed
        rows = 0_i64
        statement_error = nil.as(Exception?)

        begin
          found = nil.as(T?)
          @connection.query(plan.sql, *arguments) do |result|
            while result.move_next
              rows += 1
              raise NonUniqueResultError.new(T.name, rows) if rows > 1
              found = T.__lf_hydrate(result)
            end
          end

          if loaded = found
            register_managed(loaded, database_id)
          end
          found
        rescue error
          statement_error = error
          raise error
        ensure
          if started_at
            dispatch_statement(
              StatementCompletionEvent.new(
                StatementOperation::Select,
                T.name,
                plan.sql,
                Time.instant - started_at,
                rows,
                statement_error
              )
            )
          end
        end
      end

      def query(entity : T.class) forall T
        ensure_available(:query)

        Query::SelectQuery(
          T,
          Query::NoPredicate,
          Query::NoOrdering,
          Query::NoLimit,
          Query::NoOffset,
        ).new(self, Query::NoPredicate.new)
      end

      # Framework internal: invoked by SelectQuery(T, ...).
      def __lf_select_to_a(
        query : Query::SelectQuery(T, P, O, L, F),
      ) : Array(T) forall T, P, O, L, F
        ensure_available(:query)
        plan = @dialect.select_plan(T, Query::Rows(typeof(query)))
        execute_entity_select(T, plan.sql, query.__lf_rows_args)
      end

      # Framework internal: invoked by SelectQuery(T, ...).
      def __lf_select_first(
        query : Query::SelectQuery(T, P, O, L, F),
      ) : T? forall T, P, O, L, F
        ensure_available(:query)
        plan = @dialect.select_plan(T, Query::First(typeof(query)))
        execute_entity_select_first(T, plan.sql, query.__lf_first_args)
      end

      # Framework internal: invoked by SelectQuery(T, ...).
      def __lf_select_count(
        query : Query::SelectQuery(T, P, O, L, F),
      ) : Int64 forall T, P, O, L, F
        ensure_available(:query)
        plan = @dialect.select_plan(T, Query::Count(typeof(query)))
        execute_select_count(T.name, plan.sql, query.__lf_predicate_args)
      end

      # Framework internal: invoked by SelectQuery(T, ...).
      def __lf_select_exists(
        query : Query::SelectQuery(T, P, O, L, F),
      ) : Bool forall T, P, O, L, F
        ensure_available(:query)
        plan = @dialect.select_plan(T, Query::Exists(typeof(query)))
        execute_select_exists(T.name, plan.sql, query.__lf_predicate_args)
      end

      def flush : Nil
        ensure_available(:flush)

        begin
          do_flush
        rescue error
          @failure = error
          raise error
        end
      end

      # Framework internal: invoked by TypedTrackedEntity(T) to restore T.
      def __lf_execute_insert(entity : T, entry : Internal::TypedTrackedEntity(T)) : Nil forall T
        plan = @dialect.insert_plan(T)
        arguments = entity.__lf_insert_args

        {% begin %}
          {% id_ivar = T.instance_vars.find { |ivar| ivar.annotation(LF::Data::Id) } %}
          {% id_annotation = id_ivar.annotation(LF::Data::Id) %}
          {% if id_annotation[:generated] %}
            generated_id = case plan.generated_key_source
                           when SQL::GeneratedKeySource::LastInsertId
                             execute_observed_exec(
                               StatementOperation::Insert,
                               T.name,
                               plan.sql,
                               arguments
                             ).last_insert_id
                           when SQL::GeneratedKeySource::ReturningRow
                             execute_observed_generated_query(T.name, plan.sql, arguments)
                           else
                             raise EntityStateError.new(:insert, T.name, entry.state)
                           end
            entity.__lf_write_generated_id(generated_id)
          {% else %}
            unless plan.generated_key_source.none?
              raise EntityStateError.new(:insert, T.name, entry.state)
            end
            execute_observed_exec(
              StatementOperation::Insert,
              T.name,
              plan.sql,
              arguments
            )
          {% end %}
        {% end %}

        database_id = entity.__lf_delete_args[0].as(DB::Any)
        register_inserted(entry, database_id)
      end

      # Framework internal: invoked by TypedTrackedEntity(T) to restore T.
      def __lf_execute_update(entity : T, entry : Internal::TypedTrackedEntity(T)) : Nil forall T
        plan = @dialect.update_plan(T)
        result = execute_observed_exec(
          StatementOperation::Update,
          T.name,
          plan.sql,
          entity.__lf_update_args
        )
        if result.rows_affected == 0
          raise EntityStateError.new(:update, T.name, entry.state)
        end
        entry.state = EntityState::Managed
      end

      # Framework internal: invoked by TypedTrackedEntity(T) to restore T.
      def __lf_execute_delete(entity : T, entry : Internal::TypedTrackedEntity(T)) : Nil forall T
        plan = @dialect.delete_plan(T)
        result = execute_observed_exec(
          StatementOperation::Delete,
          T.name,
          plan.sql,
          entity.__lf_delete_args
        )
        if result.rows_affected == 0
          raise EntityStateError.new(:delete, T.name, entry.state)
        end

        if entry.has_database_id?
          @entries_by_identity.delete(Internal::EntityKey.new(T.name, entry.database_id))
        end
        entry.state = EntityState::Detached
      end

      def close : Nil
        return if closed?

        @closed = true
        begin
          do_close
        ensure
          @operation_queue.clear
          @entries_by_identity.clear
          @entries_by_object.clear
        end
      end

      protected getter connection : DB::Connection
      protected getter dialect : Dialect

      protected def dispatch_statement(event : StatementCompletionEvent) : Nil
        @dispatcher.statement_completion(event)
      end

      protected def tracked_state(entity : Reference) : EntityState?
        @entries_by_object[entity.object_id]?.try &.state
      end

      protected def tracked_operations
        @operation_queue.diagnostics
      end

      protected def register_managed(
        entity : T,
        database_id : DB::Any,
        loaded_version : Int64? = nil,
      ) : Nil forall T
        ensure_available(:register_managed)

        key = Internal::EntityKey.new(T.name, database_id)
        if existing = @entries_by_identity[key]?
          return if existing.reference.same?(entity)
          raise EntityStateError.new(:register_managed, T.name, existing.state)
        end

        entry = Internal::TypedTrackedEntity(T).new(
          entity,
          EntityState::Managed,
          database_id,
          has_database_id: true,
          loaded_version: loaded_version
        )
        @entries_by_object[entity.object_id] = entry
        @entries_by_identity[key] = entry
      end

      protected def do_flush : Nil
        while entry = @operation_queue.first?
          operation = entry.operation.not_nil!
          entry.execute(self, operation)
          @operation_queue.complete(entry)
        end
      end

      protected def do_close : Nil
      end

      private def schedule(
        entry : Internal::TrackedEntity,
        operation : Internal::EntityOperation,
      ) : Nil
        if entry.operation
          @operation_queue.schedule(entry, operation, entry.sequence.not_nil!)
        else
          sequence = @next_sequence
          @next_sequence += 1
          @operation_queue.schedule(entry, operation, sequence)
        end
      end

      private def register_inserted(
        entry : Internal::TypedTrackedEntity(T),
        database_id : DB::Any,
      ) : Nil forall T
        key = Internal::EntityKey.new(T.name, database_id)
        if existing = @entries_by_identity[key]?
          unless existing.reference.same?(entry.reference)
            raise EntityStateError.new(:insert, T.name, existing.state)
          end
        end

        entry.database_id = database_id
        entry.has_database_id = true
        entry.state = EntityState::Managed
        @entries_by_identity[key] = entry
      end

      private def execute_observed_exec(
        operation : StatementOperation,
        entity_name : String,
        sql : String,
        arguments : Tuple,
      ) : DB::ExecResult
        return @connection.exec(sql, *arguments) if @dispatcher.empty?

        started_at = Time.instant
        rows = nil.as(Int64?)
        statement_error = nil.as(Exception?)

        begin
          result = @connection.exec(sql, *arguments)
          rows = result.rows_affected
          result
        rescue error
          statement_error = error
          raise error
        ensure
          dispatch_statement(
            StatementCompletionEvent.new(
              operation,
              entity_name,
              sql,
              Time.instant - started_at,
              rows,
              statement_error
            )
          )
        end
      end

      private def execute_observed_generated_query(
        entity_name : String,
        sql : String,
        arguments : Tuple,
      ) : Int64
        if @dispatcher.empty?
          return execute_generated_query(entity_name, sql, arguments)[0]
        end

        started_at = Time.instant
        rows = 0_i64
        statement_error = nil.as(Exception?)

        begin
          generated_id, rows = execute_generated_query(entity_name, sql, arguments)
          generated_id
        rescue error
          statement_error = error
          raise error
        ensure
          dispatch_statement(
            StatementCompletionEvent.new(
              StatementOperation::Insert,
              entity_name,
              sql,
              Time.instant - started_at,
              rows,
              statement_error
            )
          )
        end
      end

      private def execute_generated_query(
        entity_name : String,
        sql : String,
        arguments : Tuple,
      ) : {Int64, Int64}
        generated_id = nil.as(Int64?)
        rows = 0_i64

        @connection.query(sql, *arguments) do |result|
          while result.move_next
            rows += 1
            raise NonUniqueResultError.new(entity_name, rows) if rows > 1
            generated_id = result.read(Int64)
          end
        end

        {generated_id || raise(MappingError.new(entity_name, nil, nil)), rows}
      end

      private def execute_entity_select(
        entity : T.class,
        sql : String,
        arguments : Tuple,
      ) : Array(T) forall T
        if @dispatcher.empty?
          entities = [] of T
          @connection.query(sql, *arguments) do |result|
            while result.move_next
              entities << managed_entity(T.__lf_hydrate(result))
            end
          end
          return entities
        end

        started_at = Time.instant
        rows = 0_i64
        statement_error = nil.as(Exception?)

        begin
          entities = [] of T
          @connection.query(sql, *arguments) do |result|
            while result.move_next
              rows += 1
              entities << managed_entity(T.__lf_hydrate(result))
            end
          end
          entities
        rescue error
          statement_error = error
          raise error
        ensure
          dispatch_select(T.name, sql, started_at, rows, statement_error)
        end
      end

      private def execute_entity_select_first(
        entity : T.class,
        sql : String,
        arguments : Tuple,
      ) : T? forall T
        if @dispatcher.empty?
          found = nil.as(T?)
          @connection.query(sql, *arguments) do |result|
            found = managed_entity(T.__lf_hydrate(result)) if result.move_next
          end
          return found
        end

        started_at = Time.instant
        rows = 0_i64
        statement_error = nil.as(Exception?)

        begin
          found = nil.as(T?)
          @connection.query(sql, *arguments) do |result|
            if result.move_next
              rows = 1_i64
              found = managed_entity(T.__lf_hydrate(result))
            end
          end
          found
        rescue error
          statement_error = error
          raise error
        ensure
          dispatch_select(T.name, sql, started_at, rows, statement_error)
        end
      end

      private def execute_select_count(
        entity_name : String,
        sql : String,
        arguments : Tuple,
      ) : Int64
        if @dispatcher.empty?
          return @connection.query_one(sql, *arguments) { |result| result.read(Int64) }
        end

        started_at = Time.instant
        rows = 0_i64
        statement_error = nil.as(Exception?)

        begin
          count = @connection.query_one(sql, *arguments) do |result|
            rows = 1_i64
            result.read(Int64)
          end
          count
        rescue error
          statement_error = error
          raise error
        ensure
          dispatch_select(entity_name, sql, started_at, rows, statement_error)
        end
      end

      private def execute_select_exists(
        entity_name : String,
        sql : String,
        arguments : Tuple,
      ) : Bool
        if @dispatcher.empty?
          exists = false
          @connection.query(sql, *arguments) { |result| exists = result.move_next }
          return exists
        end

        started_at = Time.instant
        rows = 0_i64
        statement_error = nil.as(Exception?)

        begin
          exists = false
          @connection.query(sql, *arguments) do |result|
            exists = result.move_next
            rows = 1_i64 if exists
          end
          exists
        rescue error
          statement_error = error
          raise error
        ensure
          dispatch_select(entity_name, sql, started_at, rows, statement_error)
        end
      end

      private def managed_entity(entity : T) : T forall T
        database_id = entity.__lf_delete_args[0].as(DB::Any)
        key = Internal::EntityKey.new(T.name, database_id)
        if entry = @entries_by_identity[key]?
          return entry.as(Internal::TypedTrackedEntity(T)).entity
        end

        register_managed(entity, database_id)
        entity
      end

      private def dispatch_select(
        entity_name : String,
        sql : String,
        started_at : Time::Instant,
        rows : Int64,
        error : Exception?,
      ) : Nil
        dispatch_statement(
          StatementCompletionEvent.new(
            StatementOperation::Select,
            entity_name,
            sql,
            Time.instant - started_at,
            rows,
            error
          )
        )
      end

      private def ensure_available(operation : Symbol) : Nil
        if failure = @failure
          raise FailedEntityManagerError.new(operation, failure)
        end
        raise ClosedEntityManagerError.new(operation) if closed?
      end
    end
  end
end
