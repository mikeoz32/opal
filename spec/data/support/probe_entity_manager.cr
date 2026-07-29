module LF::DataSpecSupport
  class ProbeEntityManager < LF::Data::EntityManager
    getter events = [] of Symbol

    property flush_hook : (ProbeEntityManager -> Nil)?
    property close_hook : (ProbeEntityManager -> Nil)?

    def connection_id : UInt64
      connection.object_id
    end

    def dialect_id : UInt64
      dialect.object_id
    end

    def transaction_available? : Bool
      connection.transaction { true } == true
    end

    def exec(sql : String, *args : DB::Any) : DB::ExecResult
      connection.exec(sql, *args)
    end

    def emit_statement(event : LF::Data::StatementCompletionEvent) : Nil
      dispatch_statement(event)
    end

    protected def do_flush : Nil
      @events << :flush
      @flush_hook.try &.call(self)
    end

    protected def do_close : Nil
      @events << :close
      @close_hook.try &.call(self)
    end
  end

  class ProbeDataSource < LF::Data::DataSource
    getter managers = [] of ProbeEntityManager

    property flush_hook : (ProbeEntityManager -> Nil)?
    property close_hook : (ProbeEntityManager -> Nil)?

    protected def build_entity_manager(
      connection : DB::Connection,
      dialect : LF::Data::Dialect,
      dispatcher : LF::Data::Internal::ListenerDispatcher,
    ) : LF::Data::EntityManager
      ProbeEntityManager.new(connection, dialect, dispatcher).tap do |manager|
        manager.flush_hook = @flush_hook
        manager.close_hook = @close_hook
        @managers << manager
      end
    end
  end
end
