require "./spec_helper"
require "../../src/opal/data"

describe LF::Data::Error do
  it "exposes datasource closure by class and operation" do
    error = LF::Data::ClosedDataSourceError.new(:transaction)

    error.should be_a(LF::Data::Error)
    error.operation.should eq(:transaction)
    error.message.not_nil!.should contain("transaction")
  end

  it "exposes entity manager closure by class and operation" do
    error = LF::Data::ClosedEntityManagerError.new(:flush)

    error.should be_a(LF::Data::Error)
    error.operation.should eq(:flush)
    error.message.not_nil!.should contain("flush")
  end

  it "preserves the operation and cause of a failed entity manager" do
    cause = Exception.new("write failed")
    error = LF::Data::FailedEntityManagerError.new(:persist, cause)

    error.should be_a(LF::Data::Error)
    error.operation.should eq(:persist)
    error.cause.should be(cause)
    error.message.not_nil!.should contain("persist")
  end

  it "exposes mapping context and preserves the driver cause" do
    cause = Exception.new("invalid column")
    error = LF::Data::MappingError.new("Todo", "title", "summary", cause)

    error.should be_a(LF::Data::Error)
    error.entity.should eq("Todo")
    error.property.should eq("title")
    error.column.should eq("summary")
    error.cause.should be(cause)
    error.message.not_nil!.should contain("Todo#title")
  end

  it "exposes invalid and detached entity transitions by type" do
    state_error = LF::Data::EntityStateError.new(
      :persist,
      "Todo",
      LF::Data::EntityState::Removed
    )
    detached_error = LF::Data::DetachedEntityError.new(:remove, "Todo")

    state_error.should be_a(LF::Data::Error)
    state_error.operation.should eq(:persist)
    state_error.entity_name.should eq("Todo")
    state_error.state.should eq(LF::Data::EntityState::Removed)
    detached_error.should be_a(LF::Data::EntityStateError)
    detached_error.state.should eq(LF::Data::EntityState::Detached)
  end

  it "exposes optimistic lock context" do
    error = LF::Data::OptimisticLockError.new(
      :update,
      "Todo",
      7_i64,
      3_i64
    )

    error.should be_a(LF::Data::Error)
    error.operation.should eq(:update)
    error.entity_name.should eq("Todo")
    error.entity_id.should eq(7_i64)
    error.expected_version.should eq(3_i64)
    error.message.not_nil!.should contain("expected_version=3")
  end

  it "exposes repository query ownership context" do
    error = LF::Data::RepositoryQueryOwnershipError.new("Todo")

    error.should be_a(LF::Data::Error)
    error.entity_name.should eq("Todo")
    error.message.not_nil!.should contain("different EntityManager")
  end
end
