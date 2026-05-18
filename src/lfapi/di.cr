module LF::DI
    # TODO find all annotated classes and create AutowiredApplicationConfig class
    # or move this logic into AutoriredApplicationConfig

  annotation Service
  end

  annotation Bean # Marks class method as a bean factory method
    # Parameters:
    #   name: String - The name of the bean
    #   scope: String - The scope of the bean (singleton, prototype, etc.)


  end

  module BeanFactory
    getter scope : String

  end

  module BeanInstance
  end

  class BeanFactoryImpl(T)
    include BeanFactory

    def initialize(*, name : String, scope : String = "singleton", @factory : Proc(ApplicationContext, T))
      @name = name
      @scope = scope
    end

    def create(context : ApplicationContext) : T
      @factory.call(context)

    end
  end

  class BeanInstanceImpl(T)
    include BeanInstance

    getter instance : T
    getter scope : String

    def initialize(*, instance : T, scope : String)
      @instance = instance
      @scope = scope
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
                puts factories
              end
            end
          %}
          {% for factory in factories %}
            ctx.add_bean name: {{ factory[:name] }}, type: {{ factory[:type] }}  do |ctx|
              {%for arg in factory[:args]%}
                {{ arg.name }} = ctx.get_bean("{{ arg.name }}", {{ arg.restriction }})
              {% end %}

              {{ factory[:method] }}
            end
          {% end %}
          end
        {{ debug }}
        {% end %}
      end
    end
  end

  macro finished
    class AutowiredApplicationConfig
      include ApplicationConfig
      {% for klass in Object.all_subclasses %}
        {% service_name = klass.name.stringify
              .gsub(/([A-Z]+)([A-Z][a-z])/,"\\1_\\2")
              .gsub(/([a-z0-9])([A-Z])/,"\\1_\\2")
              .downcase
        %}
        {% for ann in klass.annotations(LF::DI::Service) %}
          {% init = klass.methods.find { |method| method.name.stringify == "initialize" } %}
          {% raise "Missing initialize method" if init.nil? %}
          {% init_args = init.args.map {|arg| arg.name.stringify + " : " + arg.restriction.stringify} %}
          @[LF::DI::Bean(name: {{ service_name }})]
          def get_{{ service_name.id }}({{ init_args.join(", ").id }}) : {{ klass.id }}
            {{ klass.id }}.new({{ init.args.map(&.name.stringify).join(", ").id }})
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

    getter scope
    getter parent

    def initialize
    end

    def initialize(parent : AbstractApplicationContext, scope : String)
      raise "Singleton scope is not allowed for child contexts" if scope == "singleton"
      @scope = scope
    end

    def register(config : ApplicationConfig)
      @configurations.add(config)
      config.configure(self)
    end

    def add_bean(*, name : String, scope : String = "singleton", type : T.class, &factory : Proc(ApplicationContext, T)) forall T
      raise "Child context can not add beans" if @parent
      @factories[name] = BeanFactoryImpl(T).new(name: name, scope: scope, factory: factory).as(BeanFactory)
    end

    def get_bean(name : String, type : T.class) : T forall T
      get_bean_instance(name, type).instance
    end

    def get_bean_instance(name : String, type : T.class, caller : AbstractApplicationContext? = nil) : BeanInstanceImpl(T) forall T
      if @instances.has_key?(name)
        @instances[name].as(BeanInstanceImpl(T))
      elsif @factories.has_key?(name)
        # Root only could have facroties
        factory = @factories[name].as(BeanFactoryImpl(T))

        if !caller.nil?
          if factory.scope != "prototype" && caller.scope != factory.scope
            raise "Scope mismatch"
          end
        end

        instance = BeanInstanceImpl(T).new(instance: factory.create(caller || self), scope: factory.scope)
        if factory.scope != "prototype"
          @instances[name] = instance
        end
        instance
      elsif @parent
        instance = @parent.as(AbstractApplicationContext).get_bean_instance(name, type, caller || self)
        @instances[name] = instance
        instance
      else
        raise "Bean not found"
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
      @instances.clear
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
