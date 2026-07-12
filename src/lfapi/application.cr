module LF
  class Application
    annotation Configuration
    end

    getter context : DI::AnnotationApplicationContext

    def initialize(@context : DI::AnnotationApplicationContext = DI::AnnotationApplicationContext.new)
    end

    def self.bootstrap(context : DI::AnnotationApplicationContext = DI::AnnotationApplicationContext.new)
      application = new(context)
      application.register_configurations
      application
    end

    def self.run(context : DI::AnnotationApplicationContext = DI::AnnotationApplicationContext.new, &)
      application = bootstrap(context)

      begin
        yield application
      ensure
        application.shutdown
      end
    end

    def shutdown : Nil
      @context.shutdown
    end

    protected def register_configurations : Nil
      @context.register(DI::AutowiredApplicationConfig.new)

      {% for klass in Object.all_subclasses %}
        {% if klass.annotation(LF::Application::Configuration) && klass.ancestors.includes?(LF::DI::ApplicationConfig) %}
          @context.register({{ klass }}.new)
        {% end %}
      {% end %}
    end
  end
end
