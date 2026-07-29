require "./spec_helper"
require "../../src/opal/data"
require "../../src/opal/data/dialects/sqlite"
require "./support/sqlite_database"
require "./support/probe_entity_manager"

describe LF::Data::EntityManager do
  it "is open until close and rejects work after close" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.using_connection do |connection|
        manager = LF::Data::EntityManager.new(
          connection,
          LF::Data::Dialects::SQLite.new,
          LF::Data::Internal::ListenerDispatcher.new
        )

        manager.closed?.should be_false
        manager.flush
        manager.close
        manager.closed?.should be_true

        expect_raises(LF::Data::ClosedEntityManagerError) do
          manager.flush
        end.operation.should eq(:flush)
        expect_raises(LF::Data::ClosedEntityManagerError) do
          manager.flush
        end.operation.should eq(:flush)
      end
    end
  end

  it "propagates a flush error unchanged and becomes failed" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.using_connection do |connection|
        manager = LF::DataSpecSupport::ProbeEntityManager.new(
          connection,
          LF::Data::Dialects::SQLite.new,
          LF::Data::Internal::ListenerDispatcher.new
        )
        failure = Exception.new("flush failed")
        manager.flush_hook = ->(_manager : LF::DataSpecSupport::ProbeEntityManager) { raise failure }

        raised = expect_raises(Exception) { manager.flush }
        raised.should be(failure)

        terminal = expect_raises(LF::Data::FailedEntityManagerError) do
          manager.flush
        end
        terminal.operation.should eq(:flush)
        terminal.cause.should be(failure)

        repeated = expect_raises(LF::Data::FailedEntityManagerError) do
          manager.flush
        end
        repeated.cause.should be(failure)
      end
    end
  end

  it "closes idempotently" do
    LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
      database.using_connection do |connection|
        manager = LF::DataSpecSupport::ProbeEntityManager.new(
          connection,
          LF::Data::Dialects::SQLite.new,
          LF::Data::Internal::ListenerDispatcher.new
        )

        manager.close
        manager.close

        manager.events.should eq([:close])
      end
    end
  end
end
