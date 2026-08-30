require "./spec_helper"
require "./data/support/temp_path"

describe "Data and HTTP application lifecycle" do
  it "drains HTTP before Data closes and destroys remaining DI singletons last" do
    database_path = LF::DataSpecSupport::TempPath.database
    config_path = "/tmp/opal-data-http-#{Process.pid}-#{Random::Secure.hex(8)}.yml"
    File.write(
      config_path,
      <<-YAML
        http:
          host: 127.0.0.1
          port: 0
        database:
          url: sqlite3://#{database_path}
        YAML
    )
    fixture = File.expand_path(
      "fixtures/data/autoconfig_http_lifecycle.cr",
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
        "OPAL_CONFIG" => config_path,
      },
      output: output,
      error: error
    )

    status.success?.should be_true, error.to_s
    output.to_s.should contain("GET /data-autoconfig/drain")
    error.to_s.should eq("")
  ensure
    File.delete(config_path) if config_path && File.exists?(config_path)
    LF::DataSpecSupport::TempPath.cleanup_database(database_path) if database_path
  end
end
