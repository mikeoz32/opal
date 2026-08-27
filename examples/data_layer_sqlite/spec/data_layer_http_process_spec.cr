require "http/client"
require "spec"
require "socket"

private def reserve_data_layer_http_port : Int32
  server = nil.as(TCPServer?)
  begin
    server = TCPServer.new("127.0.0.1", 0)
    server.local_address.as(Socket::IPAddress).port
  ensure
    server.try &.close
  end
end

describe "data layer HTTP executable" do
  it "starts with a file-backed store and terminates cleanly" do
    suffix = "#{Process.pid}-#{Random.rand(1_000_000)}"
    binary = "/tmp/opal-data-layer-http-#{suffix}"
    database = "/tmp/opal-data-layer-http-#{suffix}.db"
    port = reserve_data_layer_http_port
    source = File.expand_path("../src/data_layer_example_http_cli.cr", __DIR__)
    cache_dir = ENV.fetch("CRYSTAL_CACHE_DIR", "/tmp/opal-crystal-cache")

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
      env: {
        "OPAL_DATA_EXAMPLE_URL" => "sqlite3://#{database}",
        "OPAL_DATA_HTTP_PORT" => port.to_s,
      },
      output: Process::Redirect::Close,
      error: Process::Redirect::Close
    )

    ready = false
    100.times do
      begin
        response = HTTP::Client.get("http://127.0.0.1:#{port}/health")
        if response.status == HTTP::Status::OK
          ready = true
          break
        end
      rescue IO::Error
      end
      sleep 50.milliseconds
    end
    ready.should be_true

    headers = HTTP::Headers{"Content-Type" => "application/json"}
    create = HTTP::Client.exec(
      "POST",
      "http://127.0.0.1:#{port}/projects",
      headers,
      %({"name":"process smoke"})
    )
    create.status.should eq(HTTP::Status::OK)
    duplicate = HTTP::Client.exec(
      "POST",
      "http://127.0.0.1:#{port}/projects",
      headers,
      %({"name":"process smoke"})
    )
    duplicate.status.should eq(HTTP::Status::CONFLICT)

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
  end
end
