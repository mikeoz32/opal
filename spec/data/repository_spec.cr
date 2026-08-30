require "./spec_helper"
require "../../src/opal/data"
require "../../src/opal/data/dialects/sqlite"
require "./support/sqlite_database"

@[LF::Data::Table("repository_records")]
private class RepositoryRecord
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  getter name : String
  getter category : String
  getter active : Bool

  def initialize(
    @name : String,
    @category : String,
    @active : Bool = true,
  )
    @id = nil
  end
end

@[LF::Data::Table("missing_repository_records")]
private class MissingRepositoryRecord
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : String

  def initialize(@id : String)
  end
end

private class RepositoryListener
  include LF::Data::Listener

  getter statements = [] of LF::Data::StatementCompletionEvent

  def on_statement_completion(event : LF::Data::StatementCompletionEvent) : Nil
    @statements << event
  end
end

private def with_repository_source(&block)
  LF::DataSpecSupport::SQLiteDatabase.with_memory do |database|
    database.exec(
      "CREATE TABLE repository_records (" \
      "id INTEGER PRIMARY KEY AUTOINCREMENT, " \
      "name TEXT NOT NULL, category TEXT NOT NULL, active INTEGER NOT NULL)"
    )
    listener = RepositoryListener.new
    source = LF::Data::DataSource.new(
      database,
      dialect: LF::Data::Dialects::SQLite.new,
      listeners: [listener] of LF::Data::Listener
    )
    yield database, source, listener
  end
end

private def seed_repository_records(source : LF::Data::DataSource) : Array(RepositoryRecord)
  source.transaction do |manager|
    records = [
      RepositoryRecord.new("one", "odd"),
      RepositoryRecord.new("two", "even"),
      RepositoryRecord.new("three", "odd"),
      RepositoryRecord.new("four", "even"),
      RepositoryRecord.new("five", "odd", active: false),
    ]
    records.each { |record| manager.persist(record) }
    records
  end
end

describe LF::Data::Repository do
  it "delegates typed find, find_by, count, and exists terminals" do
    with_repository_source do |database, source, listener|
      records = seed_repository_records(source)

      source.transaction do |manager|
        repository = manager.repository(RepositoryRecord)
        fields = RepositoryRecord::Fields

        found = repository.find(records.first.id.not_nil!).not_nil!
        found.name.should eq("one")
        repository.find(records.first.id.not_nil!).should be(found)
        repository.find_by(fields.name.eq("three")).not_nil!.name.should eq("three")
        repository.find_by(fields.name.eq("missing")).should be_nil
        repository.count.should eq(5_i64)
        repository.count(fields.category.eq("odd")).should eq(3_i64)
        repository.exists?.should be_true
        repository.exists?(fields.active.eq(false)).should be_true
        repository.exists?(fields.name.eq("missing")).should be_false
      end
    end
  end

  it "exposes the existing static and dynamic query APIs" do
    with_repository_source do |database, source, listener|
      seed_repository_records(source)

      source.transaction do |manager|
        repository = manager.repository(RepositoryRecord)
        fields = RepositoryRecord::Fields

        repository.query
          .where(fields.category.eq("even"))
          .order_by(fields.name.asc)
          .to_a
          .map(&.name)
          .should eq(["four", "two"])
        repository.dynamic_query
          .where(fields.name.like("%hree%"))
          .first?
          .not_nil!
          .name
          .should eq("three")
      end
    end
  end

  it "delegates entity writes and typed bulk builders without flushing" do
    with_repository_source do |database, source, listener|
      listener.statements.clear

      created = source.transaction do |manager|
        repository = manager.repository(RepositoryRecord)
        record = RepositoryRecord.new("created", "odd")

        repository.persist(record)
        repository.count.should eq(0_i64)
        record
      end

      listener.statements.map(&.operation).should eq([
        LF::Data::StatementOperation::Select,
        LF::Data::StatementOperation::Insert,
      ])

      source.transaction do |manager|
        repository = manager.repository(RepositoryRecord)
        fields = RepositoryRecord::Fields

        repository.update
          .set(fields.active, false)
          .where(fields.id.eq(created.id.not_nil!))
          .execute
          .should eq(1_i64)
        repository.delete(created.id.not_nil!).should be_true
      end

      database.scalar("SELECT count(*) FROM repository_records").should eq(0_i64)

      records = seed_repository_records(source)
      source.transaction do |manager|
        repository = manager.repository(RepositoryRecord)
        repository.remove(
          repository.find(records.first.id.not_nil!).not_nil!
        )
      end

      source.transaction do |manager|
        repository = manager.repository(RepositoryRecord)
        fields = RepositoryRecord::Fields

        repository.delete_all
          .where(fields.category.eq("even"))
          .execute
          .should eq(2_i64)
      end
      database.scalar("SELECT count(*) FROM repository_records").should eq(2_i64)
    end
  end

  it "returns deterministic one-based pages with totals" do
    with_repository_source do |database, source, listener|
      seed_repository_records(source)

      source.transaction do |manager|
        repository = manager.repository(RepositoryRecord)
        fields = RepositoryRecord::Fields

        page = repository.page(2, 2, order_by: fields.id.asc)
        page.items.map(&.name).should eq(["three", "four"])
        page.number.should eq(2_i64)
        page.page_size.should eq(2_i64)
        page.total_items.should eq(5_i64)
        page.total_pages.should eq(3_i64)
        page.empty?.should be_false

        filtered = repository.page(
          2,
          2,
          where: fields.category.eq("odd"),
          order_by: fields.id.asc
        )
        filtered.items.map(&.name).should eq(["five"])
        filtered.total_items.should eq(3_i64)
        filtered.total_pages.should eq(2_i64)

        outside = repository.page(4, 2, order_by: fields.id.asc)
        outside.items.should be_empty
        outside.total_items.should eq(5_i64)
      end
    end
  end

  it "paginates a composed query with stable multi-column ordering" do
    with_repository_source do |database, source, listener|
      seed_repository_records(source)

      source.transaction do |manager|
        repository = manager.repository(RepositoryRecord)
        fields = RepositoryRecord::Fields
        selection = repository.query
          .where(fields.category.eq("odd"))
          .where(fields.active.eq(true))
          .order_by(fields.category.asc)
          .order_by(fields.id.desc)

        page = repository.page(selection, number: 1, size: 1)
        page.items.map(&.name).should eq(["three"])
        page.total_items.should eq(2_i64)
        page.total_pages.should eq(2_i64)
        page.first?.should be_true
        page.last?.should be_false
        page.has_previous?.should be_false
        page.has_next?.should be_true

        last = repository.page(selection, number: 2, size: 1)
        last.items.map(&.name).should eq(["one"])
        last.first?.should be_false
        last.last?.should be_true
        last.has_previous?.should be_true
        last.has_next?.should be_false
      end
    end
  end

  it "rejects a composed query owned by another manager" do
    with_repository_source do |database, source, listener|
      selection = source.transaction do |manager|
        manager.repository(RepositoryRecord).query
          .order_by(RepositoryRecord::Fields.id.asc)
      end

      source.transaction do |manager|
        error = expect_raises(LF::Data::RepositoryQueryOwnershipError) do
          manager.repository(RepositoryRecord).page(
            selection,
            number: 1,
            size: 20
          )
        end
        error.entity_name.should eq("RepositoryRecord")
      end
    end
  end

  it "defines empty and invalid pagination behavior" do
    with_repository_source do |database, source, listener|
      source.transaction do |manager|
        repository = manager.repository(RepositoryRecord)
        fields = RepositoryRecord::Fields

        page = repository.page(1, 20, order_by: fields.id.asc)
        page.items.should be_empty
        page.total_items.should eq(0_i64)
        page.total_pages.should eq(0_i64)
        page.empty?.should be_true
        page.first?.should be_true
        page.last?.should be_true
        page.has_previous?.should be_false
        page.has_next?.should be_false

        page_error = expect_raises(LF::Data::InvalidQueryError) do
          repository.page(0, 20, order_by: fields.id.asc)
        end
        page_error.component.should eq(:page)

        size_error = expect_raises(LF::Data::InvalidQueryError) do
          repository.page(1, 0, order_by: fields.id.asc)
        end
        size_error.component.should eq(:page_size)
      end
    end
  end

  it "does not flush pending writes before repository reads" do
    with_repository_source do |database, source, listener|
      listener.statements.clear

      source.transaction do |manager|
        manager.persist(RepositoryRecord.new("pending", "odd"))
        repository = manager.repository(RepositoryRecord)

        repository.count.should eq(0_i64)
        repository.exists?.should be_false
      end

      listener.statements.map(&.operation).should eq([
        LF::Data::StatementOperation::Select,
        LF::Data::StatementOperation::Select,
        LF::Data::StatementOperation::Insert,
      ])
      database.scalar("SELECT count(*) FROM repository_records").should eq(1_i64)
    end
  end

  it "shares the manager lifecycle instead of owning a hidden transaction" do
    with_repository_source do |database, source, listener|
      repository = source.transaction do |manager|
        manager.repository(RepositoryRecord)
      end

      error = expect_raises(LF::Data::ClosedEntityManagerError) do
        repository.count
      end
      error.operation.should eq(:query)
    end
  end

  it "preserves native driver failures" do
    with_repository_source do |database, source, listener|
      expect_raises(SQLite3::Exception) do
        source.transaction do |manager|
          manager.repository(MissingRepositoryRecord).count
        end
      end
    end
  end
end
