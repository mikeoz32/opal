require "./spec_helper"
require "../../src/opal/data"

private class RecordingDataListener
  include LF::Data::Listener

  getter calls = [] of String

  def initialize(@name : String, @raise_on : Symbol? = nil)
  end

  def on_transaction_begin(event : LF::Data::TransactionBeginEvent) : Nil
    record(:begin)
  end

  def on_transaction_completion(event : LF::Data::TransactionCompletionEvent) : Nil
    record(:transaction_completion)
  end

  def on_statement_completion(event : LF::Data::StatementCompletionEvent) : Nil
    record(:statement_completion)
  end

  private def record(callback : Symbol) : Nil
    @calls << "#{@name}:#{callback}"
    raise "listener failed" if @raise_on == callback
  end
end

describe LF::Data::Internal::ListenerDispatcher do
  it "dispatches immutable transaction events in listener order" do
    first = RecordingDataListener.new("first")
    second = RecordingDataListener.new("second")
    dispatcher = LF::Data::Internal::ListenerDispatcher.new([first, second] of LF::Data::Listener)
    event = LF::Data::TransactionCompletionEvent.new(
      LF::Data::TransactionOutcome::Committed,
      2.milliseconds
    )

    dispatcher.transaction_begin(LF::Data::TransactionBeginEvent.new)
    dispatcher.transaction_completion(event)

    first.calls.should eq(["first:begin", "first:transaction_completion"])
    second.calls.should eq(["second:begin", "second:transaction_completion"])
    event.outcome.should eq(LF::Data::TransactionOutcome::Committed)
    event.elapsed.should eq(2.milliseconds)
  end

  it "does not invoke listeners that were not registered" do
    registered = RecordingDataListener.new("registered")
    unregistered = RecordingDataListener.new("unregistered")
    dispatcher = LF::Data::Internal::ListenerDispatcher.new([registered] of LF::Data::Listener)

    dispatcher.transaction_begin(LF::Data::TransactionBeginEvent.new)

    registered.calls.should eq(["registered:begin"])
    unregistered.calls.should be_empty
  end

  it "snapshots the listener list at construction" do
    first = RecordingDataListener.new("first")
    added_later = RecordingDataListener.new("added")
    listeners = [first] of LF::Data::Listener
    dispatcher = LF::Data::Internal::ListenerDispatcher.new(listeners)
    listeners << added_later

    dispatcher.transaction_begin(LF::Data::TransactionBeginEvent.new)

    first.calls.should eq(["first:begin"])
    added_later.calls.should be_empty
  end

  it "isolates each listener exception and continues dispatching" do
    failing = RecordingDataListener.new("failing", :statement_completion)
    healthy = RecordingDataListener.new("healthy")
    dispatcher = LF::Data::Internal::ListenerDispatcher.new([failing, healthy] of LF::Data::Listener)
    application_error = Exception.new("database failed")
    event = LF::Data::StatementCompletionEvent.new(
      LF::Data::StatementOperation::Update,
      "Todo",
      "UPDATE todos SET title = ?",
      3.milliseconds,
      nil,
      application_error
    )

    dispatcher.statement_completion(event)

    failing.calls.should eq(["failing:statement_completion"])
    healthy.calls.should eq(["healthy:statement_completion"])
    event.operation.should eq(LF::Data::StatementOperation::Update)
    event.entity_name.should eq("Todo")
    event.sql.should eq("UPDATE todos SET title = ?")
    event.elapsed.should eq(3.milliseconds)
    event.rows_affected.should be_nil
    event.error.should be(application_error)
    event.responds_to?(:bind_values).should be_false
  end

  it "has no callback cost or side effects without listeners" do
    dispatcher = LF::Data::Internal::ListenerDispatcher.new

    dispatcher.transaction_begin(LF::Data::TransactionBeginEvent.new)
    dispatcher.transaction_completion(
      LF::Data::TransactionCompletionEvent.new(
        LF::Data::TransactionOutcome::RolledBack,
        Time::Span.zero
      )
    )
  end
end
