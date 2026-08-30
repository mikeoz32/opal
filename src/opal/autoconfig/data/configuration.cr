require "uri"

module LF::Data::AutoConfig
  class Error < Exception
  end

  class ConfigurationError < Error
    def initialize(reason : String, cause : Exception? = nil)
      super("Invalid Data configuration: #{reason}", cause)
    end
  end

  class Configuration
    getter url : String
    getter dialect : LF::Data::Dialect
    getter? run_migrations_on_startup : Bool

    def initialize(
      @url : String,
      @dialect : LF::Data::Dialect,
      @run_migrations_on_startup : Bool,
    )
    end

    def self.load(config : LF::ConfigService) : self
      url = load_url(config)
      uri = parse_uri(url)
      dialect = dialect_for(uri)
      run_migrations = load_run_migrations(config)

      new(url, dialect, run_migrations)
    end

    private def self.load_url(config : LF::ConfigService) : String
      config.get("database.url").as_s
    rescue error : LF::ConfigService::MissingKeyError
      raise ConfigurationError.new("database.url is required", error)
    rescue error : TypeCastError
      raise ConfigurationError.new("database.url must be a String", error)
    end

    private def self.parse_uri(url : String) : URI
      uri = URI.parse(url)
      return uri if uri.scheme

      cause = ArgumentError.new("database URL does not contain a scheme")
      raise ConfigurationError.new("database.url must include a scheme", cause)
    rescue error : ConfigurationError
      raise error
    rescue error : Exception
      raise ConfigurationError.new("database.url is malformed", error)
    end

    private def self.dialect_for(uri : URI) : LF::Data::Dialect
      scheme = uri.scheme.not_nil!.downcase
      case scheme
      when "sqlite3"
        LF::Data::Dialects::SQLite.new
      when "postgres"
        LF::Data::Dialects::PostgreSQL.new
      else
        raise ConfigurationError.new("Unsupported database scheme: #{scheme}")
      end
    end

    private def self.load_run_migrations(config : LF::ConfigService) : Bool
      config.get("database.migrations.run_on_startup").as_bool
    rescue LF::ConfigService::MissingKeyError
      false
    rescue error : TypeCastError
      raise ConfigurationError.new(
        "database.migrations.run_on_startup must be a Bool",
        error
      )
    end
  end
end
