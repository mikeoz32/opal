require "./spec_helper"
require "../src/opal"
require "../src/opal/autoconfig/data"
require "sqlite3"
require "./data/support/temp_path"

private class DataAutoconfigMigration < LF::Data::Migration
  getter version : Int64
  getter name : String
  getter runs = 0

  def initialize(@version : Int64, @name : String, @table : String)
  end

  def up(schema : LF::Data::SchemaEditor) : Nil
    @runs += 1
    schema.create_table(@table) { |table| table.generated_id("id") }
  end
end

private class FailingDataAutoconfigMigration < LF::Data::Migration
  getter version : Int64 = 10_i64
  getter name : String = "failing"

  def up(schema : LF::Data::SchemaEditor) : Nil
    schema.create_table("must_rollback") { |table| table.generated_id("id") }
    raise "startup migration failed"
  end
end

private def with_data_autoconfig_config(contents : String, &block : String ->)
  path = "/tmp/opal-data-autoconfig-#{Process.pid}-#{Random::Secure.hex(8)}.yml"
  File.write(path, contents)
  yield path
ensure
  File.delete(path) if path && File.exists?(path)
end

private def build_data_autoconfig_runtime(
  config_path : String,
  migrations : Array(LF::Data::MigrationSet) = [] of LF::Data::MigrationSet,
) : LF::ApplicationRuntime
  root = LF::DI::DefaultContainer.new
  root.add_bean(name: "config_service", type: LF::ConfigService) do |_scope|
    LF::ConfigService.new(config_path)
  end
  migrations.each_with_index do |migration_set, index|
    root.add_bean(
      name: "migration_set_#{index}",
      type: LF::Data::MigrationSet
    ) do |_scope|
      migration_set
    end
  end
  root.resolve(LF::ConfigService)
  LF::ApplicationRuntime.new(root)
end

private def sqlite_autoconfig_yaml(
  database_path : String,
  *,
  run_migrations : Bool = false,
) : String
  <<-YAML
    database:
      url: sqlite3://#{database_path}
      migrations:
        run_on_startup: #{run_migrations}
    YAML
end

describe LF::Data::AutoConfig do
  it "records a stable priority above ordinary infrastructure extensions" do
    LF::Data::AutoConfig::Extension::PRIORITY.should eq(100)
  end

  it "parses SQLite configuration without changing URI query parameters" do
    with_data_autoconfig_config(
      "database:\n  url: sqlite3://./data.db?initial_pool_size=2&max_pool_size=5\n"
    ) do |path|
      parsed = LF::Data::AutoConfig::Configuration.load(LF::ConfigService.new(path))

      parsed.url.should eq(
        "sqlite3://./data.db?initial_pool_size=2&max_pool_size=5"
      )
      parsed.dialect.should be_a(LF::Data::Dialects::SQLite)
      parsed.run_migrations_on_startup?.should be_false
    end
  end

  it "requires database.url to be a String" do
    with_data_autoconfig_config("database:\n  url: 42\n") do |path|
      error = expect_raises(LF::Data::AutoConfig::ConfigurationError) do
        LF::Data::AutoConfig::Configuration.load(LF::ConfigService.new(path))
      end

      error.message.not_nil!.should contain("database.url must be a String")
      error.cause.should be_a(TypeCastError)
    end
  end

  it "requires database.url when Data autoconfiguration is enabled" do
    with_data_autoconfig_config("database: {}\n") do |path|
      error = expect_raises(LF::Data::AutoConfig::ConfigurationError) do
        LF::Data::AutoConfig::Configuration.load(LF::ConfigService.new(path))
      end

      error.message.not_nil!.should contain("database.url is required")
      error.cause.should be_a(LF::ConfigService::MissingKeyError)
    end
  end

  it "requires a URL scheme" do
    with_data_autoconfig_config("database:\n  url: ./data.db\n") do |path|
      error = expect_raises(LF::Data::AutoConfig::ConfigurationError) do
        LF::Data::AutoConfig::Configuration.load(LF::ConfigService.new(path))
      end

      error.message.not_nil!.should contain("database.url must include a scheme")
      error.cause.should be_a(ArgumentError)
    end
  end

  it "rejects unsupported database schemes without leaking credentials" do
    with_data_autoconfig_config(
      "database:\n  url: postgres://user:password@example.test/app\n"
    ) do |path|
      error = expect_raises(LF::Data::AutoConfig::ConfigurationError) do
        LF::Data::AutoConfig::Configuration.load(LF::ConfigService.new(path))
      end

      error.message.not_nil!.should contain("Unsupported database scheme: postgres")
      error.message.not_nil!.should_not contain("user")
      error.message.not_nil!.should_not contain("password")
    end
  end

  it "requires database.migrations.run_on_startup to be a Bool" do
    with_data_autoconfig_config(
      "database:\n  url: sqlite3://%3Amemory%3A\n  migrations:\n" \
      "    run_on_startup: yes-please\n"
    ) do |path|
      error = expect_raises(LF::Data::AutoConfig::ConfigurationError) do
        LF::Data::AutoConfig::Configuration.load(LF::ConfigService.new(path))
      end

      error.message.not_nil!.should contain(
        "database.migrations.run_on_startup must be a Bool"
      )
    end
  end

  it "registers and owns the exact DataSource singleton" do
    database_path = LF::DataSpecSupport::TempPath.database
    with_data_autoconfig_config(sqlite_autoconfig_yaml(database_path)) do |path|
      runtime = build_data_autoconfig_runtime(path)
      extension = runtime.install(LF::Data::AutoConfig::Extension.new)

      source = runtime.resolve(LF::Data::DataSource)
      source.should be(extension.data_source)
      source.transaction { |manager| manager.connection.scalar("SELECT 1") }
        .should eq(1_i64)

      runtime.shutdown
      source.closed?.should be_true
      extension.stop
    end
  ensure
    LF::DataSpecSupport::TempPath.cleanup_database(database_path) if database_path
  end

  it "does not resolve MigrationSet when startup migrations are disabled" do
    database_path = LF::DataSpecSupport::TempPath.database
    with_data_autoconfig_config(sqlite_autoconfig_yaml(database_path)) do |path|
      runtime = build_data_autoconfig_runtime(path)
      extension = runtime.install(LF::Data::AutoConfig::Extension.new)

      extension.data_source.should_not be_nil
      runtime.shutdown
    end
  ensure
    LF::DataSpecSupport::TempPath.cleanup_database(database_path) if database_path
  end

  it "runs startup migrations before bootstrap returns and skips applied work" do
    database_path = LF::DataSpecSupport::TempPath.database
    migration = DataAutoconfigMigration.new(10_i64, "create_ready", "ready")
    migrations = LF::Data::MigrationSet.new(migration)

    2.times do
      with_data_autoconfig_config(
        sqlite_autoconfig_yaml(database_path, run_migrations: true)
      ) do |path|
        runtime = build_data_autoconfig_runtime(path, [migrations])
        runtime.install(LF::Data::AutoConfig::Extension.new)

        source = runtime.resolve(LF::Data::DataSource)
        source.transaction do |manager|
          manager.connection.scalar(
            "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'ready'"
          )
        end.should eq(1_i64)
        runtime.shutdown
      end
    end

    migration.runs.should eq(1)
  ensure
    LF::DataSpecSupport::TempPath.cleanup_database(database_path) if database_path
  end

  it "supports an empty startup MigrationSet" do
    database_path = LF::DataSpecSupport::TempPath.database
    with_data_autoconfig_config(
      sqlite_autoconfig_yaml(database_path, run_migrations: true)
    ) do |path|
      runtime = build_data_autoconfig_runtime(
        path,
        [LF::Data::MigrationSet.new]
      )
      runtime.install(LF::Data::AutoConfig::Extension.new)

      source = runtime.resolve(LF::Data::DataSource)
      source.transaction do |manager|
        manager.connection.scalar(
          "SELECT count(*) FROM sqlite_master " \
          "WHERE type = 'table' AND name = '_lf_migrations'"
        )
      end.should eq(1_i64)
      runtime.shutdown
    end
  ensure
    LF::DataSpecSupport::TempPath.cleanup_database(database_path) if database_path
  end

  it "translates a missing startup MigrationSet and closes the DataSource" do
    database_path = LF::DataSpecSupport::TempPath.database
    with_data_autoconfig_config(
      sqlite_autoconfig_yaml(database_path, run_migrations: true)
    ) do |path|
      runtime = build_data_autoconfig_runtime(path)
      extension = LF::Data::AutoConfig::Extension.new

      error = expect_raises(LF::Data::AutoConfig::ConfigurationError) do
        runtime.install(extension)
      end

      error.message.not_nil!.should contain("exactly one MigrationSet is required")
      error.cause.should be_a(LF::DI::BeanNotFoundError)
      extension.data_source.not_nil!.closed?.should be_true
      runtime.closed?.should be_true
    end
  ensure
    LF::DataSpecSupport::TempPath.cleanup_database(database_path) if database_path
  end

  it "translates ambiguous startup MigrationSets and closes the DataSource" do
    database_path = LF::DataSpecSupport::TempPath.database
    with_data_autoconfig_config(
      sqlite_autoconfig_yaml(database_path, run_migrations: true)
    ) do |path|
      runtime = build_data_autoconfig_runtime(
        path,
        [LF::Data::MigrationSet.new, LF::Data::MigrationSet.new]
      )
      extension = LF::Data::AutoConfig::Extension.new

      error = expect_raises(LF::Data::AutoConfig::ConfigurationError) do
        runtime.install(extension)
      end

      error.message.not_nil!.should contain("exactly one MigrationSet is required")
      error.cause.should be_a(LF::DI::AmbiguousBeanError)
      extension.data_source.not_nil!.closed?.should be_true
    end
  ensure
    LF::DataSpecSupport::TempPath.cleanup_database(database_path) if database_path
  end

  it "preserves migration failures and closes the DataSource" do
    database_path = LF::DataSpecSupport::TempPath.database
    with_data_autoconfig_config(
      sqlite_autoconfig_yaml(database_path, run_migrations: true)
    ) do |path|
      runtime = build_data_autoconfig_runtime(
        path,
        [LF::Data::MigrationSet.new(FailingDataAutoconfigMigration.new)]
      )
      extension = LF::Data::AutoConfig::Extension.new

      expect_raises(Exception, "startup migration failed") do
        runtime.install(extension)
      end

      extension.data_source.not_nil!.closed?.should be_true
      runtime.closed?.should be_true
    end
  ensure
    LF::DataSpecSupport::TempPath.cleanup_database(database_path) if database_path
  end

  it "preserves a missing-driver cause in an isolated executable" do
    database_path = LF::DataSpecSupport::TempPath.database
    with_data_autoconfig_config(sqlite_autoconfig_yaml(database_path)) do |path|
      fixture = File.expand_path(
        "fixtures/data/autoconfig_missing_driver.cr",
        __DIR__
      )
      output = IO::Memory.new
      error = IO::Memory.new
      status = Process.run(
        "crystal",
        ["run", "--no-debug", fixture, "--", path],
        env: {
          "CRYSTAL_CACHE_DIR" => ENV.fetch(
            "CRYSTAL_CACHE_DIR",
            "/tmp/opal-crystal-cache"
          ),
        },
        output: output,
        error: error
      )

      status.success?.should be_true
      error.to_s.should eq("")
    end
  ensure
    LF::DataSpecSupport::TempPath.cleanup_database(database_path) if database_path
  end

  it "installs automatically during Application bootstrap before lower priorities" do
    database_path = LF::DataSpecSupport::TempPath.database
    with_data_autoconfig_config(sqlite_autoconfig_yaml(database_path)) do |path|
      fixture = File.expand_path(
        "fixtures/data/autoconfig_bootstrap.cr",
        __DIR__
      )
      output = IO::Memory.new
      error = IO::Memory.new
      status = Process.run(
        "crystal",
        ["run", "--no-debug", fixture],
        env: {
          "CRYSTAL_CACHE_DIR" => ENV.fetch(
            "CRYSTAL_CACHE_DIR",
            "/tmp/opal-crystal-cache"
          ),
          "OPAL_CONFIG" => path,
        },
        output: output,
        error: error
      )

      status.success?.should be_true
      error.to_s.should eq("")
    end
  ensure
    LF::DataSpecSupport::TempPath.cleanup_database(database_path) if database_path
  end
end
