module LF::DataSpecSupport
  module TempPath
    extend self

    def database : String
      "/tmp/opal-data-#{Process.pid}-#{Random::Secure.hex(8)}.db"
    end

    def cleanup_database(path : String) : Nil
      [path, "#{path}-wal", "#{path}-shm"].each do |candidate|
        File.delete(candidate) if File.exists?(candidate)
      end
    end
  end
end
