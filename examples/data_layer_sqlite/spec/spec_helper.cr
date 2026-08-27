require "spec"
require "sqlite3"
require "opal/data"
require "opal/data/dialects/sqlite"
require "../src/data_layer_example"

module DataLayerExampleSpecSupport
  extend self

  def with_store(
    allow_sqlite_cleanup_error : Bool = false,
    & : DataLayerExample::Store ->
  )
    store = DataLayerExample::Store.open("sqlite3://%3Amemory%3A")
    store.migrate
    yield store
  ensure
    begin
      store.try &.close
    rescue error : SQLite3::Exception
      raise error unless allow_sqlite_cleanup_error
    end
  end
end
