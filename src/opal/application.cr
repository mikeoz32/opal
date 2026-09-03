require "./di"
require "./config_service"

module LF
  annotation Application
  end

  annotation ApplicationConfiguration
  end

  annotation ApplicationAutoConfiguration
  end

  module ApplicationExtension
    # Marks an extension stop failure as retryable because application-owned
    # resources may still be in use. ApplicationRuntime keeps root DI alive
    # until a later shutdown attempt reports that the extension has stopped.
    module StopIncomplete
    end

    abstract def configure(context : ApplicationContext) : Nil
    abstract def stop : Nil
  end

  class ApplicationContext
    include DI::ScopeProvider

    def initialize(@container : DI::DefaultContainer)
    end

    def resolve(type : T.class) : T forall T
      @container.resolve(type)
    end

    def resolve(name : String, type : T.class) : T forall T
      @container.resolve(name, type)
    end

    # Returns whether an application extension or configuration registered a
    # bean under this exact name. Extensions use explicit names for optional
    # integration points so they do not need reflection or service discovery.
    def registered?(name : String) : Bool
      @container.has_key?(name)
    end

    def register_bean(*, name : String, scope : String = "singleton", type : T.class, &factory : DI::Container -> T) : Nil forall T
      @container.add_bean(name: name, scope: scope, type: type, &factory)
    end

    def add_bean(*, name : String, scope : String = "singleton", type : T.class, &factory : DI::Container -> T) : Nil forall T
      register_bean(name: name, scope: scope, type: type, &factory)
    end

    def enter_scope(scope : String) : DI::Container
      @container.enter_scope(scope)
    end
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

    class ShutdownError < Error
      getter extension_errors : Array(Exception)
      getter container_error : Exception?

      def initialize(@extension_errors : Array(Exception), @container_error : Exception?)
        details = extension_errors.map { |error| error.message || error.class.to_s }
        details << (container_error.message || container_error.class.to_s) if container_error
        super("Application shutdown failed: #{details.join(" | ")}")
      end
    end

    class InstallError < Error
      getter configure_error : Exception
      getter cleanup_errors : Array(Exception)
      getter pending_runtime : ApplicationRuntime?

      def initialize(
        @configure_error : Exception,
        @cleanup_errors : Array(Exception),
        @pending_runtime : ApplicationRuntime? = nil,
      )
        details = cleanup_errors.map { |error| error.message || error.class.to_s }
        super("Application extension installation and cleanup failed: #{details.join(" | ")}")
      end
    end

    @closed = false
    @shutdown_started = false
    @context : ApplicationContext
    @extensions = [] of ApplicationExtension

    def initialize(@container : DI::DefaultContainer)
      @context = ApplicationContext.new(@container)
    end

    def closed? : Bool
      @closed
    end

    def shutdown_pending? : Bool
      @shutdown_started && !@closed
    end

    def resolve(type : T.class) : T forall T
      ensure_open
      @container.resolve(type)
    end

    def resolve(name : String, type : T.class) : T forall T
      ensure_open
      @container.resolve(name, type)
    end

    def install(extension : T) : T forall T
      ensure_open

      begin
        extension.configure(@context)
      rescue configure_error : Exception
        cleanup_errors = [] of Exception
        stop_incomplete = false
        begin
          extension.stop
        rescue cleanup_error : Exception
          cleanup_errors << cleanup_error
          if cleanup_error.is_a?(ApplicationExtension::StopIncomplete)
            # The partially configured extension may still own work that uses
            # application beans. Retain it as the newest extension and leave
            # its dependencies and root DI alive for a later shutdown retry.
            @extensions << extension
            @shutdown_started = true
            stop_incomplete = true
          end
        end
        unless stop_incomplete
          begin
            shutdown
          rescue cleanup_error : Exception
            cleanup_errors << cleanup_error
          end
        end

        if cleanup_errors.empty?
          raise configure_error
        else
          raise InstallError.new(
            configure_error,
            cleanup_errors,
            stop_incomplete ? self : nil
          )
        end
      end

      @extensions << extension
      extension
    end

    def shutdown : Nil
      raise AlreadyClosedError.new if @closed
      @shutdown_started = true

      extension_errors = [] of Exception
      extension_index = @extensions.size - 1
      while extension_index >= 0
        extension = @extensions[extension_index]
        begin
          extension.stop
        rescue error : Exception
          extension_errors << error
          if error.is_a?(ApplicationExtension::StopIncomplete)
            # Earlier extensions may own resources still used by the incomplete
            # extension. Preserve their reverse-order shutdown dependency.
            @extensions = @extensions[0..extension_index]
            raise ShutdownError.new(extension_errors, nil)
          end
        end
        extension_index -= 1
      end

      @extensions.clear

      container_error : Exception? = nil
      begin
        @container.shutdown
      rescue error : Exception
        container_error = error
      ensure
        @closed = true
      end

      if extension_errors.empty?
        raise container_error.as(Exception) if container_error
      else
        raise ShutdownError.new(extension_errors, container_error)
      end
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
      raise ClosedError.new if @shutdown_started
    end
  end
end

macro finished
    {% autoconfigurations = [] of NamedTuple %}
    {% for klass in Object.all_subclasses %}
      {% if descriptor = klass.annotation(LF::ApplicationAutoConfiguration) %}
        {% enabled_by = descriptor["enabled_by"] %}
        {% unless enabled_by %}
          {% raise "Invalid application autoconfiguration enabled_by for #{klass.name}: attribute is required" %}
        {% end %}
        {% enabled_marker = enabled_by.resolve? %}
        {% unless enabled_marker && !enabled_marker.class? && !enabled_marker.module? && !enabled_marker.struct? && !enabled_marker.union? %}
          {% raise "Invalid application autoconfiguration enabled_by for #{klass.name}: expected annotation type" %}
        {% end %}
        {% marker_probe = klass.annotation(enabled_marker) %}
        {% descriptor_attributes = descriptor.named_args.keys.map(&.stringify) %}
        {% priority = descriptor_attributes.includes?("priority") ? descriptor["priority"] : 0 %}
        {% unless priority.is_a?(NumberLiteral) && priority.kind != :f32 && priority.kind != :f64 %}
          {% raise "Invalid application autoconfiguration priority for #{klass.name}: expected integer literal" %}
        {% end %}
        {% if klass.abstract? %}
          {% raise "Invalid application autoconfiguration type for #{klass.name}: must be concrete" %}
        {% end %}
        {% unless klass.ancestors.includes?(LF::ApplicationExtension) %}
          {% raise "Invalid application autoconfiguration type for #{klass.name}: must include LF::ApplicationExtension" %}
        {% end %}
        {% initializers = klass.methods.select { |method| method.name.stringify == "initialize" } %}
        {% if initializers.empty? %}
          {% for ancestor in klass.ancestors %}
            {% if initializers.empty? %}
              {% inherited_initializers = ancestor.methods.select { |method| method.name.stringify == "initialize" } %}
              {% unless inherited_initializers.empty? %}
                {% initializers = inherited_initializers %}
              {% end %}
            {% end %}
          {% end %}
        {% end %}
        {% has_zero_argument_constructor = initializers.empty? %}
        {% for initializer in initializers %}
          {% required_arguments = [] of ASTNode %}
          {% for argument, index in initializer.args %}
            {% splat_argument = !initializer.splat_index.is_a?(NilLiteral) && initializer.splat_index == index %}
            {% optional_splat = splat_argument && argument.restriction.is_a?(Nop) %}
            {% has_default = !argument.default_value.is_a?(Nop) %}
            {% unless has_default || optional_splat %}
              {% required_arguments << argument %}
            {% end %}
          {% end %}
          {% if required_arguments.empty? && initializer.block_arg.is_a?(Nop) %}
            {% has_zero_argument_constructor = true %}
          {% end %}
        {% end %}
        {% unless has_zero_argument_constructor %}
          {% raise "Invalid application autoconfiguration constructor for #{klass.name}: expected zero-argument initialize" %}
        {% end %}
        {% autoconfigurations << {type: klass, enabled_by: enabled_by, priority: priority, name: klass.name.stringify} %}
      {% end %}
    {% end %}

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
      {% unless app_priority.is_a?(NumberLiteral) && app_priority.kind != :f32 && app_priority.kind != :f64 %}
        {% raise "Invalid application priority for #{application.name}: expected Int32" %}
      {% end %}
      {% providers << {type: application, priority: app_priority, name: application.name.stringify} %}

      {% for klass in Object.all_subclasses %}
        {% if config_annotation = klass.annotation(LF::ApplicationConfiguration) %}
          {% priority = config_annotation["priority"] || 0 %}
          {% unless priority.is_a?(NumberLiteral) && priority.kind != :f32 && priority.kind != :f64 %}
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
      {% enabled_autoconfigurations = [] of NamedTuple %}
      {% for autoconfiguration in autoconfigurations %}
        {% if application.annotation(autoconfiguration[:enabled_by].resolve) %}
          {% enabled_autoconfigurations << autoconfiguration %}
        {% end %}
      {% end %}
      {% ordered_autoconfigurations = [] of NamedTuple %}
      {% ascending_autoconfiguration_priorities = enabled_autoconfigurations.map { |autoconfiguration| autoconfiguration[:priority] }.uniq.sort %}
      {% autoconfiguration_priorities = [] of NumberLiteral %}
      {% for priority in ascending_autoconfiguration_priorities %}
        {% autoconfiguration_priorities.unshift(priority) %}
      {% end %}
      {% for priority in autoconfiguration_priorities %}
        {% same_priority = enabled_autoconfigurations.select { |autoconfiguration| autoconfiguration[:priority] == priority }.sort_by { |autoconfiguration| autoconfiguration[:name] } %}
        {% for autoconfiguration in same_priority %}
          {% ordered_autoconfigurations << autoconfiguration %}
        {% end %}
      {% end %}

      class {{ application }}
        def self.bootstrap : LF::ApplicationRuntime
          container = LF::DI::DefaultContainer.new
          runtime = nil.as(LF::ApplicationRuntime?)

          begin
            container.register(LF::DI::ServiceConfiguration.new)
            container.add_bean(name: "config_service", type: LF::ConfigService) do |_ctx|
              LF::ConfigService.new
            end
            container.resolve("config_service", LF::ConfigService)
            {% for provider in ordered_providers %}
              container.register_provider({{ provider[:type] }}.new)
            {% end %}
            created_runtime = LF::ApplicationRuntime.new(container)
            runtime = created_runtime
            {% for autoconfiguration in ordered_autoconfigurations %}
              created_runtime.install({{ autoconfiguration[:type] }}.new)
            {% end %}
            created_runtime
          rescue error : Exception
            if active_runtime = runtime
              unless active_runtime.closed? || active_runtime.shutdown_pending?
                begin
                  active_runtime.shutdown
                rescue cleanup_error : Exception
                  raise LF::ApplicationRuntime::InstallError.new(
                    error,
                    [cleanup_error] of Exception,
                    active_runtime.shutdown_pending? ? active_runtime : nil
                  )
                end
              end
            else
              begin
                container.shutdown
              rescue
              end
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
