require "./spec_helper"
require "../../src/opal/data"
require "../../src/opal/data/dialects/sqlite"
require "./support/sqlite_database"

private class StateEntity
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : String

  property value : String

  def initialize(@id : String, @value : String)
  end
end

private class StateProbeEntityManager < LF::Data::EntityManager
  def state_of(entity : Reference) : LF::Data::EntityState?
    tracked_state(entity)
  end

  def queued_operations
    tracked_operations
  end

  def mark_managed(entity : T) : Nil forall T
    register_managed(entity, entity.__lf_delete_args[0])
  end
end

private class StateProbeDataSource < LF::Data::DataSource
  getter managers = [] of StateProbeEntityManager

  protected def build_entity_manager(
    connection : DB::Connection,
    dialect : LF::Data::Dialect,
    dispatcher : LF::Data::Internal::ListenerDispatcher,
  ) : LF::Data::EntityManager
    manager = StateProbeEntityManager.new(connection, dialect, dispatcher)
    @managers << manager
    manager
  end
end

private def with_state_manager(& : StateProbeEntityManager ->)
  LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
    source = StateProbeDataSource.new(
      database,
      dialect: LF::Data::Dialects::SQLite.new
    )
    begin
      source.transaction do |manager|
        yield manager.as(StateProbeEntityManager)
        raise DB::Rollback.new("state-only test")
      end
    rescue DB::Rollback
    end
  ensure
    source.try &.close
  end
end

describe LF::Data::EntityManager do
  it "tracks an unknown entity as New and schedules one INSERT" do
    with_state_manager do |manager|
      entity = StateEntity.new("same-id", "first")

      manager.persist(entity)
      manager.persist(entity)

      manager.state_of(entity).should eq(LF::Data::EntityState::New)
      manager.queued_operations.should eq([
        {LF::Data::Internal::EntityOperation::Insert, entity.object_id, 0_i64},
      ])
    end
  end

  it "does not infer lifecycle state from an assigned ID" do
    with_state_manager do |manager|
      first = StateEntity.new("same-id", "first")
      second = StateEntity.new("same-id", "second")

      manager.persist(first)
      manager.persist(second)

      manager.state_of(first).should eq(LF::Data::EntityState::New)
      manager.state_of(second).should eq(LF::Data::EntityState::New)
      manager.queued_operations.size.should eq(2)
    end
  end

  it "cancels a new INSERT and detaches the entity on remove" do
    with_state_manager do |manager|
      entity = StateEntity.new("id", "value")
      manager.persist(entity)

      manager.remove(entity)

      manager.state_of(entity).should eq(LF::Data::EntityState::Detached)
      manager.queued_operations.should be_empty
      expect_raises(LF::Data::DetachedEntityError) { manager.persist(entity) }
      expect_raises(LF::Data::DetachedEntityError) { manager.remove(entity) }
    end
  end

  it "rejects remove for an unknown entity" do
    with_state_manager do |manager|
      entity = StateEntity.new("id", "value")

      error = expect_raises(LF::Data::EntityStateError) { manager.remove(entity) }

      error.operation.should eq(:remove)
      error.state.should be_nil
    end
  end

  it "coalesces managed UPDATE and replaces it with DELETE in place" do
    with_state_manager do |manager|
      first = StateEntity.new("first", "value")
      second = StateEntity.new("second", "value")
      manager.mark_managed(first)
      manager.mark_managed(second)

      manager.persist(first)
      manager.persist(second)
      manager.persist(first)
      manager.remove(first)
      manager.remove(first)

      manager.state_of(first).should eq(LF::Data::EntityState::Removed)
      manager.queued_operations.should eq([
        {LF::Data::Internal::EntityOperation::Delete, first.object_id, 0_i64},
        {LF::Data::Internal::EntityOperation::Update, second.object_id, 1_i64},
      ])
      error = expect_raises(LF::Data::EntityStateError) { manager.persist(first) }
      error.state.should eq(LF::Data::EntityState::Removed)
    end
  end

  it "rejects every stateful operation after close" do
    manager = nil.as(StateProbeEntityManager?)
    entity = StateEntity.new("id", "value")

    with_state_manager do |active_manager|
      manager = active_manager
      active_manager.persist(entity)
    end

    expect_raises(LF::Data::ClosedEntityManagerError) { manager.not_nil!.persist(entity) }
    expect_raises(LF::Data::ClosedEntityManagerError) { manager.not_nil!.remove(entity) }
  end
end
