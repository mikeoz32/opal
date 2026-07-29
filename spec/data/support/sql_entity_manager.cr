module LF::DataSpecSupport
  class SQLEntityManager < LF::Data::EntityManager
    def exec(sql : String, *arguments : DB::Any) : DB::ExecResult
      connection.exec(sql, *arguments)
    end

    def state_of(entity : Reference) : LF::Data::EntityState?
      tracked_state(entity)
    end

    def queued_operations
      tracked_operations
    end
  end

  class SQLEntityDataSource < LF::Data::DataSource
    getter managers = [] of SQLEntityManager

    protected def build_entity_manager(
      connection : DB::Connection,
      dialect : LF::Data::Dialect,
      dispatcher : LF::Data::Internal::ListenerDispatcher,
    ) : LF::Data::EntityManager
      SQLEntityManager.new(connection, dialect, dispatcher).tap do |manager|
        @managers << manager
      end
    end
  end
end
