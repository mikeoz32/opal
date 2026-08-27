require "http/client"
require "json"
require "spec"
require "socket"

private def reserve_data_layer_application_http_port : Int32
  server = nil.as(TCPServer?)
  begin
    server = TCPServer.new("127.0.0.1", 0)
    server.local_address.as(Socket::IPAddress).port
  ensure
    server.try &.close
  end
end

describe "data layer Application HTTP executable" do
  it "bootstraps DI, migrations, controller routes, and clean shutdown" do
    suffix = "#{Process.pid}-#{Random.rand(1_000_000)}"
    binary = "/tmp/opal-data-layer-application-http-#{suffix}"
    database = "/tmp/opal-data-layer-application-http-#{suffix}.db"
    config = "/tmp/opal-data-layer-application-http-#{suffix}.yml"
    port = reserve_data_layer_application_http_port
    source = File.expand_path("../src/data_layer_example_application_cli.cr", __DIR__)
    cache_dir = ENV.fetch("CRYSTAL_CACHE_DIR", "/tmp/opal-crystal-cache")
    File.write(
      config,
      "http:\n  host: 127.0.0.1\n  port: #{port}\ndatabase:\n  url: sqlite3://#{database}\n"
    )

    compile_output = IO::Memory.new
    compile_error = IO::Memory.new
    compile_status = Process.run(
      "crystal",
      ["build", source, "-o", binary],
      env: {"CRYSTAL_CACHE_DIR" => cache_dir},
      output: compile_output,
      error: compile_error
    )
    compile_status.success?.should be_true, compile_error.to_s

    process = Process.new(
      binary,
      env: {"OPAL_CONFIG" => config},
      output: Process::Redirect::Close,
      error: Process::Redirect::Close
    )

    ready = false
    100.times do
      begin
        response = HTTP::Client.get("http://127.0.0.1:#{port}/health")
        if response.status == HTTP::Status::OK
          response.content_type.should eq("application/json")
          JSON.parse(response.body)["status"].as_s.should eq("ok")
          ready = true
          break
        end
      rescue IO::Error
      end
      sleep 50.milliseconds
    end
    ready.should be_true

    headers = HTTP::Headers{"Content-Type" => "application/json"}
    project = HTTP::Client.exec(
      "POST",
      "http://127.0.0.1:#{port}/projects",
      headers,
      %({"name":"application smoke"})
    )
    project.status.should eq(HTTP::Status::OK)
    project.content_type.should eq("application/json")
    project_id = JSON.parse(project.body)["id"].as_i64
    project_id.should eq(1_i64)

    duplicate = HTTP::Client.exec(
      "POST",
      "http://127.0.0.1:#{port}/projects",
      headers,
      %({"name":"application smoke"})
    )
    duplicate.status.should eq(HTTP::Status::CONFLICT)

    projects = HTTP::Client.get("http://127.0.0.1:#{port}/projects")
    projects.status.should eq(HTTP::Status::OK)
    projects.content_type.should eq("application/json")
    JSON.parse(projects.body)["projects"].as_a.size.should eq(1)

    task = HTTP::Client.exec(
      "POST",
      "http://127.0.0.1:#{port}/projects/#{project_id}/tasks",
      headers,
      %({"title":"exercise controller discovery"})
    )
    task.status.should eq(HTTP::Status::OK)
    task.content_type.should eq("application/json")
    task_id = JSON.parse(task.body)["id"].as_i64

    tasks = HTTP::Client.get("http://127.0.0.1:#{port}/projects/#{project_id}/tasks")
    tasks.status.should eq(HTTP::Status::OK)
    JSON.parse(tasks.body)["tasks"].as_a.size.should eq(1)

    updated = HTTP::Client.exec(
      "PATCH",
      "http://127.0.0.1:#{port}/tasks/#{task_id}",
      headers,
      %({"completed":true})
    )
    updated.status.should eq(HTTP::Status::OK)
    JSON.parse(updated.body)["completed"].as_bool.should be_true

    invalid_update = HTTP::Client.exec(
      "PATCH",
      "http://127.0.0.1:#{port}/tasks/#{task_id}",
      headers,
      %({})
    )
    invalid_update.status.should eq(HTTP::Status::BAD_REQUEST)

    invalid_json = HTTP::Client.exec(
      "POST",
      "http://127.0.0.1:#{port}/projects",
      headers,
      "not json"
    )
    invalid_json.status.should eq(HTTP::Status::BAD_REQUEST)

    deleted = HTTP::Client.exec(
      "DELETE",
      "http://127.0.0.1:#{port}/tasks/#{task_id}",
      headers
    )
    deleted.status.should eq(HTTP::Status::OK)
    deleted.content_type.should eq("text/plain")
    deleted.body.should eq("deleted")

    empty_tasks = HTTP::Client.get("http://127.0.0.1:#{port}/projects/#{project_id}/tasks")
    JSON.parse(empty_tasks.body)["tasks"].as_a.should be_empty

    missing = HTTP::Client.get("http://127.0.0.1:#{port}/projects/999/tasks")
    missing.status.should eq(HTTP::Status::NOT_FOUND)

    process.terminate
    status = process.wait
    status.success?.should be_true
  ensure
    if process && !process.terminated?
      process.terminate(graceful: false)
      process.wait
    end
    File.delete(binary) if binary && File.exists?(binary)
    File.delete(database) if database && File.exists?(database)
    File.delete(config) if config && File.exists?(config)
  end
end
