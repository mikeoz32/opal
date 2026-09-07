require "db"
require "./data/entity_state"
require "./data/entity_key"
require "./data/errors"
require "./data/migration_lock"
require "./data/listener"
require "./data/mapping_annotations"
require "./data/migration"
require "./data/migration_set"
require "./data/schema/index_definition"
require "./data/schema/operation"
require "./data/schema/table_builder"
require "./data/relationship"
require "./data/schema/model"
require "./data/schema/snapshot"
require "./data/schema/diff"
require "./data/schema/migration_source_generator"
require "./data/schema/introspector"
require "./data/schema/renderer"
require "./data/schema_editor"
require "./data/converter"
require "./data/hydrator"
require "./data/query/shape"
require "./data/query/expression"
require "./data/query/field"
require "./data/entity"
require "./data/query/select_query"
require "./data/query/rendered_query"
require "./data/query/dynamic_renderer"
require "./data/query/dynamic_query"
require "./data/query/update_query"
require "./data/query/delete_query"
require "./data/operation_queue"
require "./data/sql/statement_plan"
require "./data/sql/insert_plan"
require "./data/sql/query_token"
require "./data/sql/static_plan_compiler"
require "./data/dialect_capability"
require "./data/dialect"
require "./data/migration_history"
require "./data/entity_manager"
require "./data/repository"
require "./data/data_source"
require "./data/schema/migration_generator"
require "./data/migration_runner"

module LF
  # Explicit, transaction-local persistence APIs.
  #
  # This module is opt-in through `require "opal/data"`. An application also
  # chooses and imports a concrete driver and dialect, for example
  # `opal/data/dialects/sqlite` plus `sqlite3` or
  # `opal/data/dialects/postgresql` plus `pg`.
  #
  # Entity managers exist only inside `DataSource#transaction`; entities never
  # perform lazy relationship queries. Migrations are ordered and forward-only.
  module Data
  end
end
