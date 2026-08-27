require "./spec_helper"

describe "generated run_http entrypoint" do
  it "closes cleanly on a termination request" do
    suffix = "#{Process.pid}-#{Random.rand(1_000_000)}"
    binary = "/tmp/opal-run-http-#{suffix}"
    config = "/tmp/opal-run-http-#{suffix}.yml"
    process = nil.as(Process?)
    fixture = File.expand_path("fixtures/http/run_http_application.cr", __DIR__)
    File.write(config, "http:\n  host: 127.0.0.1\n  port: 0\n")

    compile_output = IO::Memory.new
    compile_error = IO::Memory.new
    compile_status = Process.run(
      "crystal",
      ["build", fixture, "-o", binary],
      env: {"CRYSTAL_CACHE_DIR" => ENV.fetch("CRYSTAL_CACHE_DIR", "/tmp/opal-crystal-cache")},
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
    sleep 100.milliseconds
    process.terminated?.should be_false

    process.terminate
    completed = Channel(Process::Status).new
    spawn { completed.send(process.wait) }

    select
    when status = completed.receive
      status.success?.should be_true
    when timeout(5.seconds)
      process.terminate(graceful: false)
      fail "run_http did not stop within 5 seconds"
    end
  ensure
    if process && !process.terminated?
      process.terminate(graceful: false)
      process.wait
    end
    File.delete(binary) if binary && File.exists?(binary)
    File.delete(config) if config && File.exists?(config)
  end
end
