require "../../opal"
require "../data"
require "../data/dialects/sqlite"
require "./data/configuration"

module LF::AutoConfig
  annotation Data
  end
end

module LF::Data::AutoConfig
  @[LF::ApplicationAutoConfiguration(
    enabled_by: LF::AutoConfig::Data,
    priority: 100
  )]
  class Extension
    include LF::ApplicationExtension

    PRIORITY = 100

    getter data_source : LF::Data::DataSource?
    getter? configured = false
    getter? stopped = false

    def configure(context : LF::ApplicationContext) : Nil
      configuration = Configuration.load(context.resolve(LF::ConfigService))
      source = open_source(configuration)
      @data_source = source

      context.register_bean(
        name: "data_source",
        type: LF::Data::DataSource
      ) do |_scope|
        configured_data_source
      end
      context.resolve("data_source", LF::Data::DataSource)

      if configuration.run_migrations_on_startup?
        migrations = resolve_migrations(context)
        LF::Data::MigrationRunner.new(source).run(migrations)
      end

      @configured = true
    end

    def stop : Nil
      return if stopped?

      @data_source.try(&.close)
      @stopped = true
    end

    private def open_source(configuration : Configuration) : LF::Data::DataSource
      LF::Data::DataSource.open(
        configuration.url,
        dialect: configuration.dialect
      )
    rescue error : Exception
      raise ConfigurationError.new("Failed to open configured database", error)
    end

    private def resolve_migrations(
      context : LF::ApplicationContext,
    ) : LF::Data::MigrationSet
      context.resolve(LF::Data::MigrationSet)
    rescue error : LF::DI::BeanNotFoundError | LF::DI::AmbiguousBeanError
      raise ConfigurationError.new(
        "exactly one MigrationSet is required when startup migrations are enabled",
        error
      )
    end

    private def configured_data_source : LF::Data::DataSource
      @data_source || raise Error.new("DataSource is not configured")
    end
  end
end

macro finished
  {% for klass in Object.all_subclasses %}
    {% if klass.annotation(LF::AutoConfig::Data) && !klass.annotation(LF::Application) %}
      {% raise "@[LF::AutoConfig::Data] requires @[LF::Application] on #{klass.name}" %}
    {% end %}
  {% end %}
end
