require "./spec_helper"
require "../src/opal"

private def with_config_file(contents : String, &block : String ->)
  path = "/tmp/opal-config-service-#{Process.pid}-#{Random.rand(1_000_000)}.yml"
  File.write(path, contents)
  yield path
ensure
  File.delete(path) if path && File.exists?(path)
end

describe LF::ConfigService do
  it "loads values and sections from a YAML file" do
    with_config_file(<<-YAML) do |path|
      http:
        host: 127.0.0.1
        port: 9090
      features:
        - api
        - jobs
      YAML
      config = LF::ConfigService.new(path)

      config.get("http.host").as_s.should eq("127.0.0.1")
      config.get("http.port").as_i.should eq(9090)
      config.section("http")["port"].as_i.should eq(9090)
      config.get("features").as_a.map(&.as_s).should eq(["api", "jobs"])
    end
  end

  it "does not expose mutable internal YAML mappings" do
    with_config_file("http:\n  port: 8080\n") do |path|
      config = LF::ConfigService.new(path)
      section = config.section("http")
      section.as_h[YAML::Any.new("port")] = YAML::Any.new(9090_i64)

      config.get("http.port").as_i.should eq(8080)
    end
  end

  it "returns a typed default only when a key is missing" do
    with_config_file("http:\n  port: 9090\n") do |path|
      config = LF::ConfigService.new(path)

      config.get("http.port", 8080).should eq(9090)
      config.get("http.host", "0.0.0.0").should eq("0.0.0.0")
    end
  end

  it "raises a typed error for a missing key" do
    with_config_file("{}\n") do |path|
      config = LF::ConfigService.new(path)

      expect_raises(LF::ConfigService::MissingKeyError, "Missing configuration key: http.port") do
        config.get("http.port")
      end
    end
  end

  it "raises a typed load error for an explicitly selected missing file" do
    path = "/tmp/opal-missing-config-#{Process.pid}-#{Random.rand(1_000_000)}.yml"

    expect_raises(LF::ConfigService::LoadError, "Configuration file does not exist: #{path}") do
      LF::ConfigService.new(path)
    end
  end

  it "raises a typed load error for malformed YAML" do
    with_config_file("http: [\n") do |path|
      expect_raises(LF::ConfigService::LoadError, "Failed to load configuration from #{path}") do
        LF::ConfigService.new(path)
      end
    end
  end

  it "uses OPAL_CONFIG when no path is passed" do
    previous = ENV["OPAL_CONFIG"]?

    with_config_file("name: selected\n") do |path|
      ENV["OPAL_CONFIG"] = path
      LF::ConfigService.new.get("name").as_s.should eq("selected")
    end
  ensure
    if previous
      ENV["OPAL_CONFIG"] = previous
    else
      ENV.delete("OPAL_CONFIG")
    end
  end

  it "uses empty configuration when the default file is missing" do
    previous = ENV["OPAL_CONFIG"]?
    original_dir = Dir.current
    directory = "/tmp/opal-empty-config-#{Process.pid}-#{Random.rand(1_000_000)}"
    Dir.mkdir(directory)
    ENV.delete("OPAL_CONFIG")
    Dir.cd(directory)

    config = LF::ConfigService.new

    config.get("missing", "default").should eq("default")
    expect_raises(LF::ConfigService::MissingKeyError) do
      config.get("missing")
    end
  ensure
    Dir.cd(original_dir) if original_dir
    Dir.delete(directory) if directory && Dir.exists?(directory)
    if previous
      ENV["OPAL_CONFIG"] = previous
    else
      ENV.delete("OPAL_CONFIG")
    end
  end
end
