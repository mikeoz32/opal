module LF::DI
    # TODO find all annotated classes and create AutowiredApplicationConfig class
    # or move this logic into AutoriredApplicationConfig

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
    abstract def scope : String
    abstract def owner_context_id : UInt64
    abstract def destroy_if_disposable : Nil
  end

  class BeanFactoryImpl(T)
    include BeanFactory

    def initialize(*, name : String, scope : String = "singleton", @factory : Proc(ApplicationContext, T))
      @name = name
      @scope = scope
      @type_name = T.to_s
    end

    def create(context : ApplicationContext) : T
      @factory.call(context)

    end
  end

  class BeanInstanceImpl(T)
    include BeanInstance

    getter instance : T
    getter scope : String
    getter owner_scope : String
    getter owner_context_id : UInt64

    def initialize(*, instance : T, scope : String, owner_scope : String, owner_context_id : UInt64)
      @instance = instance
      @scope = scope
      @owner_scope = owner_scope
      @owner_context_id = owner_context_id
    end

    def destroy_if_disposable : Nil
      disposable = @instance.as?(Disposable)
      disposable.try(&.destroy)
    end
  end

  module ApplicationContext
    # ApplicationContext interface
    # Should be included in implementations
  end

  module ApplicationConfig
    # ApplicationConfig interface
    # Should be included in implementations

    macro included
      macro finished
        {% verbatim do %}
          def configure(ctx : LF::DI::AbstractApplicationContext)
          {% factories = [] of NamedTuple %}
          {%
            @type.methods.each do |method|
              method.annotations(LF::DI::Bean).each do |ann|
                bean_name = ann["name"] || method.name.stringify
                factories << { name: bean_name, method: method.body, type: method.return_type, args: method.args }
              end
            end
          %}
          {% for factory in factories %}
            ctx.add_bean name: {{ factory[:name] }}, type: {{ factory[:type] }}  do |ctx|
              {%for arg in factory[:args]%}
                {{ arg.name }} = ctx.resolve_dependency("{{ arg.name }}", {{ arg.restriction }})
              {% end %}

              {{ factory[:method] }}
            end
          {% end %}
          end
        {% end %}
      end
    end
  end

  macro finished
    class AutowiredApplicationConfig
      include ApplicationConfig
      {% for klass, idx in Object.all_subclasses %}
        {% service_name = klass.name.stringify
              .gsub(/([A-Z]+)([A-Z][a-z])/,"\\1_\\2")
              .gsub(/([a-z0-9])([A-Z])/,"\\1_\\2")
              .downcase
        %}
        {% for ann in klass.annotations(LF::DI::Service) %}
          {% init = klass.methods.find { |method| method.name.stringify == "initialize" } %}
          {% init_args = init ? init.args.map {|arg| arg.name.stringify + " : " + arg.restriction.stringify} : [] of String %}
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

  abstract class AbstractApplicationContext
    include ApplicationContext

    @configurations : Set(ApplicationConfig) = Set(ApplicationConfig).new
    @factories = Hash(String, BeanFactory).new
    @parent : AbstractApplicationContext?
    @scope : String = "singleton"
    @instances = Hash(String, BeanInstance).new
    @owned_instance_order = [] of String

    getter scope
    getter parent

    def initialize
    end

    def initialize(parent : AbstractApplicationContext, scope : String)
      raise InvalidChildScopeError.new(scope) if scope == "singleton"
      @parent = parent
      @scope = scope
    end

    def register(config : ApplicationConfig)
      @configurations.add(config)
      config.configure(self)
    end

    def add_bean(*, name : String, scope : String = "singleton", type : T.class, &factory : Proc(ApplicationContext, T)) forall T
      raise ChildContextMutationError.new if @parent
      raise DuplicateBeanError.new(name) if @factories.has_key?(name)
      @factories[name] = BeanFactoryImpl(T).new(name: name, scope: scope, factory: factory).as(BeanFactory)
    end

    def get_bean(name : String, type : T.class) : T forall T
      get_bean_instance(name, type).instance
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
      if instance.owner_context_id == object_id && !@owned_instance_order.includes?(name)
        @owned_instance_order << name
      end
    end

    protected def visible_factory_names : Array(String)
      names = [] of String
      context : AbstractApplicationContext? = self

      while context
        context.as(AbstractApplicationContext).factories.each_key do |name|
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
        @parent.as(AbstractApplicationContext).find_factory(name)
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

    def get_bean_instance(name : String, type : T.class, caller : AbstractApplicationContext? = nil) : BeanInstanceImpl(T) forall T
      if @instances.has_key?(name)
        @instances[name].as(BeanInstanceImpl(T))
      elsif @factories.has_key?(name)
        # Root only could have facroties
        factory_meta = @factories[name]
        if factory_meta.type_name != T.to_s
          raise BeanTypeMismatchError.new(name, T.to_s, factory_meta.type_name)
        end
        factory = factory_meta.as(BeanFactoryImpl(T))

        if !caller.nil?
          if factory.scope != "prototype" && caller.scope != factory.scope
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
          instance: created,
          scope: factory.scope,
          owner_scope: owner.scope,
          owner_context_id: owner.object_id
        )
        if factory.scope != "prototype"
          owner.cache_instance(name, instance)
        end
        instance
      elsif @parent
        instance = @parent.as(AbstractApplicationContext).get_bean_instance(name, type, caller || self)
        @instances[name] = instance if instance.scope != "prototype"
        instance
      else
        raise BeanNotFoundError.new(name, T.to_s)
      end
    end

    def to_t(name : String, type : T.class) : T forall T
      get_bean(name, type)
    end

    delegate has_key?, to: @factories

    def enter_scope(scope : String)
      self.class.new(self, scope)
    end

    def exit
      if @parent
        errors = [] of String
        each_owned_instance_in_destroy_order do |name, bean|
          begin
            bean.destroy_if_disposable
          rescue ex : Exception
            reason = ex.message || ex.class.to_s
            errors << "name=#{name}, scope=#{bean.scope}, reason=#{reason}"
          end
        end

        unless errors.empty?
          raise BeanDestructionError.new("Lifecycle error: phase=destroy, scope=#{scope}, failures=#{errors.size}; #{errors.join(" | ")}")
        end
      end

      @instances.clear
      @owned_instance_order.clear
    end

    def shutdown
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
      @owned_instance_order.clear

      unless errors.empty?
        raise BeanDestructionError.new("Lifecycle error: phase=destroy, scope=#{scope}, failures=#{errors.size}; #{errors.join(" | ")}")
      end
    end

    private def each_owned_instance_in_destroy_order(&block : String, BeanInstance ->)
      @owned_instance_order.reverse_each do |name|
        bean = @instances[name]?
        next unless bean
        next unless bean.owner_context_id == object_id
        yield name, bean
      end
    end
  end

  class AnnotationApplicationContext < AbstractApplicationContext
  end
end

# Pass tuple as arguments to a function
# def test1(a : String, b : Int32)
#   puts "test1 called"
# end

# t = {"test", 1}

# test1(*t)
