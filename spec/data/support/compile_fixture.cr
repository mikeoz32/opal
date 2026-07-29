module LF::DataSpecSupport
  def self.compile_fixture(path : String) : NamedTuple(status: Process::Status, output: String, error: String)
    output = IO::Memory.new
    error = IO::Memory.new
    cache_dir = ENV.fetch("CRYSTAL_CACHE_DIR", "/tmp/opal-crystal-cache")
    Dir.mkdir_p(cache_dir)

    status = Process.run(
      "crystal",
      ["build", "--no-codegen", path],
      env: {"CRYSTAL_CACHE_DIR" => cache_dir},
      output: output,
      error: error
    )

    {status: status, output: output.to_s, error: error.to_s}
  end

  def self.compile_fixture_ir(path : String) : NamedTuple(
    status: Process::Status,
    output: String,
    error: String,
    ir: String,
  )
    output = IO::Memory.new
    error = IO::Memory.new
    cache_dir = ENV.fetch("CRYSTAL_CACHE_DIR", "/tmp/opal-crystal-cache")
    artifact = "/tmp/opal-static-plan-#{Process.pid}-#{Time.utc.to_unix_ms}"
    ir_path = "#{artifact}.ll"
    Dir.mkdir_p(cache_dir)

    begin
      status = Process.run(
        "crystal",
        [
          "build",
          "--no-debug",
          "--single-module",
          "--emit",
          "llvm-ir",
          "-o",
          artifact,
          path,
        ],
        env: {"CRYSTAL_CACHE_DIR" => cache_dir},
        output: output,
        error: error
      )

      {
        status: status,
        output: output.to_s,
        error:  error.to_s,
        ir:     File.exists?(ir_path) ? File.read(ir_path) : "",
      }
    ensure
      File.delete(artifact) if File.exists?(artifact)
      File.delete(ir_path) if File.exists?(ir_path)
    end
  end
end
