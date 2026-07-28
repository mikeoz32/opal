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
end
