module LF::DI
  class Error < Exception
  end

  class InvalidChildScopeError < Error
    def initialize(scope : String)
      message = scope == "singleton" ? "Singleton scope is not allowed for child contexts" : "Invalid child scope: #{scope}"
      super(message)
    end
  end

  class ChildContextMutationError < Error
    def initialize
      super("Child context can not add beans")
    end
  end

  class ContextClosedError < Error
    def initialize(scope : String)
      super("DI context is closed: scope=#{scope}")
    end
  end

  class DuplicateBeanError < Error
    def initialize(name : String)
      super("Bean already registered: name=#{name}")
    end
  end

  class BeanTypeMismatchError < Error
    def initialize(name : String, expected : String, actual : String)
      super("Bean type mismatch: name=#{name}, expected=#{expected}, actual=#{actual}")
    end
  end

  class ScopeMismatchError < Error
    def initialize(name : String, bean_scope : String, caller_scope : String)
      super("Scope mismatch: name=#{name}, bean_scope=#{bean_scope}, caller_scope=#{caller_scope}")
    end
  end

  class BeanNotFoundError < Error
    def initialize(name : String, type_name : String)
      super("Bean not found: name=#{name}, type=#{type_name}")
    end
  end

  class AmbiguousBeanError < Error
    def initialize(type_name : String, candidates : Array(String))
      super("Ambiguous beans for type #{type_name}: #{candidates.join(", ")}")
    end
  end

  class BeanInitializationError < Error
    def initialize(bean_name : String, bean_type : String, scope : String, reason : String)
      super("Lifecycle error: phase=init, bean_name=#{bean_name}, bean_type=#{bean_type}, scope=#{scope}, reason=#{reason}")
    end
  end

  class BeanDestructionError < Error
    def initialize(message : String)
      super(message)
    end
  end

  module Initializable
    abstract def after_properties_set : Nil
  end

  module Disposable
    abstract def destroy : Nil
  end

  module ScopeProvider
    abstract def enter_scope(scope : String) : Container
  end

  annotation Service
  end

  annotation Bean # Marks class method as a bean factory method
    # Parameters:
    #   name: String - The name of the bean
    #   scope: String - The scope of the bean (singleton, prototype, etc.)


  end

  module BeanFactory
    getter name : String
    getter scope : String
    getter type_name : String
  end

  module BeanInstance
    abstract def name : String
    abstract def scope : String
    abstract def type_name : String
    abstract def owner_context_id : UInt64
    abstract def destroy_if_disposable : Nil
  end

  class BeanFactoryImpl(T)
    include BeanFactory

    def initialize(*, name : String, scope : String = "singleton", @factory : Proc(Container, T))
      @name = name
      @scope = scope
      @type_name = T.to_s
    end

    def create(context : Container) : T
      @factory.call(context)
    end
  end

  class BeanInstanceImpl(T)
    include BeanInstance

    getter name : String
    getter instance : T
    getter scope : String
    getter type_name : String
    getter owner_scope : String
    getter owner_context_id : UInt64

    def initialize(*, @name : String, instance : T, scope : String, owner_scope : String, owner_context_id : UInt64)
      @instance = instance
      @scope = scope
      @type_name = T.to_s
      @owner_scope = owner_scope
      @owner_context_id = owner_context_id
    end

    def destroy_if_disposable : Nil
      if disposable = @instance.as?(Disposable)
        disposable.destroy
      end
    end
  end

  module BeanConfiguration
    macro included
      macro finished
        {% verbatim do %}
          def configure(ctx : LF::DI::Container) : Nil
            ctx.register_provider(self)
          end
        {% end %}
      end
    end
  end

  macro finished
    class ServiceConfiguration
      include BeanConfiguration
      {% for klass, idx in Object.all_subclasses %}
        {% service_name = klass.name.stringify
             .gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
             .gsub(/([a-z0-9])([A-Z])/, "\\1_\\2")
             .downcase %}
        {% for ann in klass.annotations(LF::DI::Service) %}
          {% init = klass.methods.find { |method| method.name.stringify == "initialize" } %}
          {% init_args = init ? init.args.map { |arg| arg.name.stringify + " : " + arg.restriction.stringify } : [] of String %}
          @[LF::DI::Bean(name: {{ service_name }})]
          def __autowired_service_{{ idx.id }}({{ init_args.join(", ").id }}) : {{ klass.id }}
            {% if init %}
              {{ klass.id }}.new({{ init.args.map(&.name.stringify).join(", ").id }})
            {% else %}
              {{ klass.id }}.new
            {% end %}
          end
        {% end %}
      {% end %}
    end
  end

  abstract class Container
    include ScopeProvider

    @configurations : Set(BeanConfiguration) = Set(BeanConfiguration).new
    @factories = Hash(String, BeanFactory).new
    @parent : Container?
    @scope : String = "singleton"
    @closed = false
    @instances = Hash(String, BeanInstance).new
    @owned_instances = [] of BeanInstance

    getter scope
    getter parent

    def closed? : Bool
      @closed
    end

    def initialize
    end

    def initialize(parent : Container, scope : String)
      raise InvalidChildScopeError.new(scope) if scope == "singleton"
      @parent = parent
      @scope = scope
    end

    def register(config : BeanConfiguration)
      ensure_open
      @configurations.add(config)
      config.configure(self)
    end

    def register_provider(provider : T) : Nil forall T
      ensure_open

      {% for method in T.methods %}
        {% for ann in method.annotations(LF::DI::Bean) %}
          {% bean_name = ann["name"] || method.name.stringify %}
          {% bean_scope = ann["scope"] || "singleton" %}
          add_bean(name: {{ bean_name }}, scope: {{ bean_scope }}, type: {{ method.return_type }}) do |ctx|
            {% for argument in method.args %}
              {{ argument.name }} = ctx.resolve_dependency("{{ argument.name }}", {{ argument.restriction }})
            {% end %}
            provider.{{ method.name }}({% for argument in method.args %}{{ argument.name }},{% end %})
          end
        {% end %}
      {% end %}
    end

    def add_bean(*, name : String, scope : String = "singleton", type : T.class, &factory : Proc(Container, T)) forall T
      ensure_open
      raise ChildContextMutationError.new if @parent
      raise DuplicateBeanError.new(name) if @factories.has_key?(name)
      @factories[name] = BeanFactoryImpl(T).new(name: name, scope: scope, factory: factory).as(BeanFactory)
    end

    def get_bean(name : String, type : T.class) : T forall T
      get_bean_instance(name, type).instance
    end

    def resolve(type : T.class) : T forall T
      get_bean_by_type(type)
    end

    def resolve(name : String, type : T.class) : T forall T
      get_bean(name, type)
    end

    def resolve_dependency(name : String, type : T.class) : T forall T
      begin
        get_bean(name, type)
      rescue BeanNotFoundError | BeanTypeMismatchError
        get_bean_by_type(type)
      end
    end

    protected def cache_instance(name : String, instance : BeanInstance)
      @instances[name] = instance
    end

    protected def track_owned_instance(instance : BeanInstance)
      @owned_instances << instance
    end

    protected def visible_factory_names : Array(String)
      names = [] of String
      context : Container? = self

      while context
        context.as(Container).factories.each_key do |name|
          names << name unless names.includes?(name)
        end
        context = context.parent
      end

      names
    end

    protected getter factories : Hash(String, BeanFactory)

    protected def bean_names_for_type(type_name : String) : Array(String)
      visible_factory_names.select do |name|
        factory = find_factory(name)
        !factory.nil? && factory.as(BeanFactory).type_name == type_name
      end
    end

    protected def find_factory(name : String) : BeanFactory?
      if factory = @factories[name]?
        factory
      elsif @parent
        @parent.as(Container).find_factory(name)
      else
        nil
      end
    end

    protected def get_bean_by_type(type : T.class) : T forall T
      candidates = bean_names_for_type(T.to_s)

      case candidates.size
      when 0
        raise BeanNotFoundError.new("<type:#{T}>", T.to_s)
      when 1
        get_bean(candidates.first, type)
      else
        raise AmbiguousBeanError.new(T.to_s, candidates)
      end
    end

    def get_bean_instance(name : String, type : T.class, caller : Container? = nil) : BeanInstanceImpl(T) forall T
      ensure_open
      if @instances.has_key?(name)
        cached = @instances[name]
        if cached.type_name != T.to_s
          raise BeanTypeMismatchError.new(name, T.to_s, cached.type_name)
        end
        cached.as(BeanInstanceImpl(T))
      elsif @factories.has_key?(name)
        factory_meta = @factories[name]
        if factory_meta.type_name != T.to_s
          raise BeanTypeMismatchError.new(name, T.to_s, factory_meta.type_name)
        end
        factory = factory_meta.as(BeanFactoryImpl(T))

        if !caller.nil?
          if factory.scope != "prototype" && factory.scope != "singleton" && caller.scope != factory.scope
            raise ScopeMismatchError.new(name, factory.scope, caller.scope)
          end
        end

        created = factory.create(caller || self)
        begin
          if created.is_a?(Initializable)
            created.after_properties_set
          end
        rescue ex : Exception
          reason = ex.message || ex.class.to_s
          raise BeanInitializationError.new(name, T.to_s, (caller || self).scope, reason)
        end

        owner = factory.scope == "singleton" ? self : (caller || self)
        instance = BeanInstanceImpl(T).new(
          name: name,
          instance: created,
          scope: factory.scope,
          owner_scope: owner.scope,
          owner_context_id: owner.object_id
        )
        owner.track_owned_instance(instance)
        if factory.scope != "prototype"
          owner.cache_instance(name, instance)
        end
        instance
      elsif @parent
        instance = @parent.as(Container).get_bean_instance(name, type, caller || self)
        @instances[name] = instance if instance.scope != "prototype"
        instance
      else
        raise BeanNotFoundError.new(name, T.to_s)
      end
    end

    def has_key?(name : String) : Bool
      ensure_open
      @instances.has_key?(name) || !find_factory(name).nil?
    end

    def enter_scope(scope : String) : Container
      ensure_open
      self.class.new(self, scope)
    end

    def exit : Nil
      close
    end

    def shutdown : Nil
      close
    end

    private def close : Nil
      return if @closed
      @closed = true
      errors = [] of String

      each_owned_instance_in_destroy_order do |name, bean|
        begin
          bean.destroy_if_disposable
        rescue ex : Exception
          reason = ex.message || ex.class.to_s
          errors << "name=#{name}, scope=#{bean.scope}, reason=#{reason}"
        end
      end

      @instances.clear
      @owned_instances.clear

      unless errors.empty?
        raise BeanDestructionError.new("Lifecycle error: phase=destroy, scope=#{scope}, failures=#{errors.size}; #{errors.join(" | ")}")
      end
    end

    private def ensure_open : Nil
      raise ContextClosedError.new(scope) if @closed
    end

    private def each_owned_instance_in_destroy_order(&block : String, BeanInstance ->)
      @owned_instances.reverse_each do |bean|
        next unless bean.owner_context_id == object_id
        yield bean.name, bean
      end
    end
  end

  class DefaultContainer < Container
  end
end
