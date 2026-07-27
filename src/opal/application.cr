require "./di"

module LF
  annotation Application
  end

  annotation ApplicationConfiguration
  end

  class ApplicationRuntime
    class Error < Exception
    end

    class ClosedError < Error
      def initialize
        super("Application runtime is closed")
      end
    end

    class AlreadyClosedError < Error
      def initialize
        super("Application runtime is already closed")
      end
    end

    class RunError < Error
      getter block_error : Exception
      getter shutdown_error : Exception

      def initialize(@block_error : Exception, @shutdown_error : Exception)
        super("Application run and shutdown both failed")
      end
    end

    @closed = false

    def initialize(@container : DI::DefaultContainer)
    end

    def closed? : Bool
      @closed
    end

    def resolve(type : T.class) : T forall T
      ensure_open
      @container.resolve(type)
    end

    def resolve(name : String, type : T.class) : T forall T
      ensure_open
      @container.resolve(name, type)
    end

    def shutdown : Nil
      raise AlreadyClosedError.new if @closed
      @closed = true
      @container.shutdown
    end

    def self.run(runtime : ApplicationRuntime, &block : ApplicationRuntime -> T) : T forall T
      result = uninitialized T
      block_error : Exception? = nil

      begin
        result = yield runtime
      rescue error : Exception
        block_error = error
      end

      shutdown_error : Exception? = nil
      begin
        runtime.shutdown
      rescue error : Exception
        shutdown_error = error
      end

      if block_error && shutdown_error
        raise RunError.new(block_error.as(Exception), shutdown_error.as(Exception))
      elsif block_error
        raise block_error.as(Exception)
      elsif shutdown_error
        raise shutdown_error.as(Exception)
      end

      result
    end

    private def ensure_open : Nil
      raise ClosedError.new if @closed
    end
  end
end

macro finished
    {% applications = Object.all_subclasses.select { |klass| klass.annotation(LF::Application) } %}
    {% if applications.size > 1 %}
      {% names = applications.map(&.name.stringify).sort %}
      {% raise "Only one @[LF::Application] is allowed per executable: #{names.join(", ")}" %}
    {% end %}

    {% unless applications.empty? %}
      {% application = applications.first %}
      {% providers = [] of NamedTuple %}
      {% app_annotation = application.annotation(LF::Application) %}
      {% app_priority = app_annotation["priority"] || 0 %}
      {% unless app_priority.is_a?(NumberLiteral) %}
        {% raise "Invalid application priority for #{application.name}: expected Int32" %}
      {% end %}
      {% providers << {type: application, priority: app_priority, name: application.name.stringify} %}

      {% for klass in Object.all_subclasses %}
        {% if config_annotation = klass.annotation(LF::ApplicationConfiguration) %}
          {% priority = config_annotation["priority"] || 0 %}
          {% unless priority.is_a?(NumberLiteral) %}
            {% raise "Invalid application configuration priority for #{klass.name}: expected Int32" %}
          {% end %}
          {% providers << {type: klass, priority: priority, name: klass.name.stringify} %}
        {% end %}
      {% end %}
      {% ordered_providers = [] of NamedTuple %}
      {% priorities = providers.map { |provider| provider[:priority] }.uniq.sort_by { |priority| -priority } %}
      {% for priority in priorities %}
        {% same_priority = providers.select { |provider| provider[:priority] == priority }.sort_by { |provider| provider[:name] } %}
        {% for provider in same_priority %}
          {% ordered_providers << provider %}
        {% end %}
      {% end %}

      class {{ application }}
        def self.bootstrap : LF::ApplicationRuntime
          container = LF::DI::DefaultContainer.new

          begin
            container.register(LF::DI::ServiceConfiguration.new)
            {% for provider in ordered_providers %}
              container.register_provider({{ provider[:type] }}.new)
            {% end %}
            LF::ApplicationRuntime.new(container)
          rescue error : Exception
            begin
              container.shutdown
            rescue
            end
            raise error
          end
        end

        def self.run(&block : LF::ApplicationRuntime -> T) : T forall T
          LF::ApplicationRuntime.run(bootstrap) do |runtime|
            yield runtime
          end
        end
      end
    {% end %}
end
