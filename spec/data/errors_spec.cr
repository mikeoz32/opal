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
end
