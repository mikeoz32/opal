require "http/client"
require "json"
require "socket"
require "./spec_helper"

private def reserve_todo_api_port : Int32
  server = nil.as(TCPServer?)
  begin
    server = TCPServer.new("127.0.0.1", 0)
    server.local_address.as(Socket::IPAddress).port
  ensure
    server.try &.close
  end
end

private def wait_for_todo_api(port : Int32) : Nil
  100.times do
    begin
      response = HTTP::Client.get("http://127.0.0.1:#{port}/todos")
      return if response.status == HTTP::Status::OK
    rescue IO::Error
    end
    sleep 50.milliseconds
  end
  raise "Todo API did not become ready"
end

describe "Todo Data HTTP executable" do
  it "persists CRUD across restart and applies its migration once" do
    suffix = "#{Process.pid}-#{Random.rand(1_000_000)}"
    binary = "/tmp/opal-todo-api-#{suffix}"
    database = "/tmp/opal-todo-api-#{suffix}.db"
    config = "/tmp/opal-todo-api-#{suffix}.yml"
    port = reserve_todo_api_port
    process = nil.as(Process?)
    source = File.expand_path("../src/todo_api_sqlite_example.cr", __DIR__)
    cache_dir = ENV.fetch("CRYSTAL_CACHE_DIR", "/tmp/opal-crystal-cache")
    File.write(
      config,
      "http:\n  host: 127.0.0.1\n  port: #{port}\n" \
      "database:\n  url: sqlite3://#{database}\n" \
      "  migrations:\n    run_on_startup: true\n"
    )

    compile_error = IO::Memory.new
    compile_status = Process.run(
      "crystal",
      ["build", source, "-o", binary],
      env: {"CRYSTAL_CACHE_DIR" => cache_dir},
      output: Process::Redirect::Close,
      error: compile_error
    )
    compile_status.success?.should be_true, compile_error.to_s

    process = Process.new(
      binary,
      env: {"OPAL_CONFIG" => config},
      output: Process::Redirect::Close,
      error: Process::Redirect::Close
    )
    wait_for_todo_api(port)

    JSON.parse(HTTP::Client.get("http://127.0.0.1:#{port}/todos").body)["todos"]
      .as_a.should be_empty
    headers = HTTP::Headers{"Content-Type" => "application/json"}
    created = HTTP::Client.exec(
      "POST",
      "http://127.0.0.1:#{port}/todos",
      headers,
      %({"title":"release Data"})
    )
    created.status.should eq(HTTP::Status::OK)
    created_body = JSON.parse(created.body)
    todo_id = created_body["id"].as_i64
    created_body["version"].as_i64.should eq(0_i64)

    HTTP::Client.get("http://127.0.0.1:#{port}/todos/#{todo_id}")
      .status.should eq(HTTP::Status::OK)
    updated = HTTP::Client.exec(
      "PUT",
      "http://127.0.0.1:#{port}/todos/#{todo_id}",
      headers,
      %({"completed":true})
    )
    JSON.parse(updated.body)["version"].as_i64.should eq(1_i64)
    JSON.parse(updated.body)["completed"].as_bool.should be_true
    listed = JSON.parse(
      HTTP::Client.get("http://127.0.0.1:#{port}/todos").body
    )["todos"].as_a
    listed.size.should eq(1)
    listed.first["id"].as_i64.should eq(todo_id)
    listed.first["completed"].as_bool.should be_true

    HTTP::Client.get("http://127.0.0.1:#{port}/todos/999")
      .status.should eq(HTTP::Status::NOT_FOUND)
    HTTP::Client.exec(
      "PUT",
      "http://127.0.0.1:#{port}/todos/999",
      headers,
      %({"title":"missing"})
    ).status.should eq(HTTP::Status::NOT_FOUND)
    HTTP::Client.exec(
      "DELETE",
      "http://127.0.0.1:#{port}/todos/999",
      headers
    ).status.should eq(HTTP::Status::NOT_FOUND)

    process.terminate
    process.wait.success?.should be_true
    process = nil

    process = Process.new(
      binary,
      env: {"OPAL_CONFIG" => config},
      output: Process::Redirect::Close,
      error: Process::Redirect::Close
    )
    wait_for_todo_api(port)
    persisted = JSON.parse(
      HTTP::Client.get("http://127.0.0.1:#{port}/todos/#{todo_id}").body
    )
    persisted["title"].as_s.should eq("release Data")
    persisted["version"].as_i64.should eq(1_i64)

    deleted = HTTP::Client.exec(
      "DELETE",
      "http://127.0.0.1:#{port}/todos/#{todo_id}",
      headers
    )
    deleted.status.should eq(HTTP::Status::OK)
    deleted.body.should eq("deleted")

    process.terminate
    process.wait.success?.should be_true
    process = nil

    DB.open("sqlite3:#{database}") do |verification_database|
      verification_database.scalar(
        "SELECT count(*) FROM _lf_migrations"
      ).should eq(1_i64)
    end
  ensure
    if process && !process.terminated?
      process.terminate(graceful: false)
      process.wait
    end
    File.delete(binary) if binary && File.exists?(binary)
    File.delete(config) if config && File.exists?(config)
    TodoExampleSpecSupport.cleanup_database(database) if database
  end
end
