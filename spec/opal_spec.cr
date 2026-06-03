require "./spec_helper"
require "../src/opal"
require "http/client"

class JsonModel
  include JSON::Serializable

  property id : Int32
  property name : String

  def initialize(@id : Int32, @name : String)
  end
end

class TestResourceForDI
  include LF::APIRoute

  @[LF::APIRoute::Get("/test")]
  def test_endpoint(name : String)
    "Hello #{name}"
  end
end

class TestAPIWithParams
  include LF::APIRoute

  @[LF::APIRoute::Get("/users/:id")]
  def get_user(id : Int32)
    "User #{id}"
  end

  @[LF::APIRoute::Get("/items/:item_id")]
  def get_item(item_id : Int64)
    "Item #{item_id}"
  end

  @[LF::APIRoute::Get("/products/:product_id")]
  def get_product(product_id : UUID)
    "Product #{product_id}"
  end

  @[LF::APIRoute::Get("/settings/:key")]
  def get_setting(key : String, enabled : Bool)
    "Setting #{key} is #{enabled}"
  end
end

class TestResourceJsonResponse
  include LF::APIRoute

  @[LF::APIRoute::Get("/json-response")]
  def json_response
    LF::JSONResponse.create(JsonModel.new(1, "ok"))
  end
end

class TestCounterService
  getter id : Int32

  @@next_id = 0

  def initialize
    @@next_id += 1
    @id = @@next_id
  end

  def self.reset
    @@next_id = 0
  end
end

class TestGreetingService
  getter message : String

  def initialize(@message : String)
  end
end

class TestConfigWithBeans
  include LF::DI::ApplicationConfig

  @[LF::DI::Bean]
  def greeting_service : TestGreetingService
    TestGreetingService.new("hello")
  end

  @[LF::DI::Bean(name: "custom_counter")]
  def counter_service : TestCounterService
    TestCounterService.new
  end
end

@[LF::DI::Service]
class AutoLeafService
  def value : String
    "leaf"
  end
end

@[LF::DI::Service]
class AutoParentService
  getter auto_leaf_service : AutoLeafService

  def initialize(@auto_leaf_service : AutoLeafService)
  end

  def value : String
    "parent->#{auto_leaf_service.value}"
  end
end

@[LF::DI::Service]
class AutoMiddleService
  getter auto_leaf_service : AutoLeafService

  def initialize(@auto_leaf_service : AutoLeafService)
  end

  def value : String
    "middle->#{auto_leaf_service.value}"
  end
end

@[LF::DI::Service]
class AutoTopService
  getter auto_parent_service : AutoParentService
  getter auto_middle_service : AutoMiddleService

  def initialize(@auto_parent_service : AutoParentService, @auto_middle_service : AutoMiddleService)
  end

  def value : String
    "#{auto_parent_service.value}|#{auto_middle_service.value}"
  end
end

@[LF::DI::Service]
class AutoMismatchedArgService
  def initialize(@leaf : AutoLeafService)
  end

  def value : String
    @leaf.value
  end
end

class TestLifecycleBean
  include LF::DI::Initializable
  include LF::DI::Disposable

  getter init_called = false
  getter destroy_called = false

  def after_properties_set : Nil
    @init_called = true
  end

  def destroy : Nil
    @destroy_called = true
  end
end

class TestInitCounterBean
  include LF::DI::Initializable

  @@init_calls = 0

  def self.reset
    @@init_calls = 0
  end

  def self.init_calls
    @@init_calls
  end

  def after_properties_set : Nil
    @@init_calls += 1
  end
end

class TestFailingInitBean
  include LF::DI::Initializable

  @@instances = 0

  def self.reset
    @@instances = 0
  end

  def self.instances
    @@instances
  end

  def initialize
    @@instances += 1
  end

  def after_properties_set : Nil
    raise "init boom"
  end
end

class TestDisposableCounterBean
  include LF::DI::Disposable

  @@destroy_calls = 0

  def self.reset
    @@destroy_calls = 0
  end

  def self.destroy_calls
    @@destroy_calls
  end

  def destroy : Nil
    @@destroy_calls += 1
  end
end

class TestFailingDisposableBean
  include LF::DI::Disposable

  def destroy : Nil
    raise "destroy boom"
  end
end

class TestOrderedDisposableBean
  include LF::DI::Disposable

  @@destroy_order = [] of String

  def self.reset
    @@destroy_order = [] of String
  end

  def self.destroy_order
    @@destroy_order
  end

  def initialize(@label : String)
  end

  def destroy : Nil
    @@destroy_order << @label
  end
end

@[LF::DI::Service]
class AutoLifecycleLeafService
  include LF::DI::Initializable
  include LF::DI::Disposable

  @@init_calls = 0
  @@destroy_calls = 0
  @@lifecycle_trace = [] of String

  def self.reset
    @@init_calls = 0
    @@destroy_calls = 0
    @@lifecycle_trace = [] of String
  end

  def self.init_calls
    @@init_calls
  end

  def self.destroy_calls
    @@destroy_calls
  end

  def self.lifecycle_trace
    @@lifecycle_trace
  end

  def after_properties_set : Nil
    @@init_calls += 1
  end

  def destroy : Nil
    @@destroy_calls += 1
    @@lifecycle_trace << "leaf"
  end
end

@[LF::DI::Service]
class AutoLifecycleParentService
  include LF::DI::Initializable
  include LF::DI::Disposable

  getter auto_lifecycle_leaf_service : AutoLifecycleLeafService

  @@init_calls = 0
  @@destroy_calls = 0

  def self.reset
    @@init_calls = 0
    @@destroy_calls = 0
  end

  def self.init_calls
    @@init_calls
  end

  def self.destroy_calls
    @@destroy_calls
  end

  def initialize(@auto_lifecycle_leaf_service : AutoLifecycleLeafService)
  end

  def after_properties_set : Nil
    @@init_calls += 1
  end

  def destroy : Nil
    @@destroy_calls += 1
    AutoLifecycleLeafService.lifecycle_trace << "parent"
  end
end

class TestDependentConfig
  include LF::DI::ApplicationConfig

  @[LF::DI::Bean]
  def greeting_service : TestGreetingService
    TestGreetingService.new("hello")
  end

  @[LF::DI::Bean]
  def decorated_message(greeting_service : TestGreetingService) : String
    "#{greeting_service.message}, world"
  end
end

class TestTypeFallbackConfig
  include LF::DI::ApplicationConfig

  @[LF::DI::Bean]
  def fallback_greeting : TestGreetingService
    TestGreetingService.new("fallback")
  end

  @[LF::DI::Bean]
  def decorated_message(greeting_service : TestGreetingService) : String
    "#{greeting_service.message}, world"
  end
end

class TestNamePreferredConfig
  include LF::DI::ApplicationConfig

  @[LF::DI::Bean]
  def greeting_service : TestGreetingService
    TestGreetingService.new("named")
  end

  @[LF::DI::Bean]
  def alternate_greeting : TestGreetingService
    TestGreetingService.new("alternate")
  end

  @[LF::DI::Bean]
  def decorated_message(greeting_service : TestGreetingService) : String
    greeting_service.message
  end
end

class TestTypeMismatchFallbackConfig
  include LF::DI::ApplicationConfig

  @[LF::DI::Bean]
  def greeting_service : String
    "wrong type"
  end

  @[LF::DI::Bean]
  def backup_greeting : TestGreetingService
    TestGreetingService.new("backup")
  end

  @[LF::DI::Bean]
  def decorated_message(greeting_service : TestGreetingService) : String
    greeting_service.message
  end
end

class TestAmbiguousTypeFallbackConfig
  include LF::DI::ApplicationConfig

  @[LF::DI::Bean]
  def primary_greeting : TestGreetingService
    TestGreetingService.new("primary")
  end

  @[LF::DI::Bean]
  def secondary_greeting : TestGreetingService
    TestGreetingService.new("secondary")
  end

  @[LF::DI::Bean]
  def decorated_message(greeting : TestGreetingService) : String
    greeting.message
  end
end

describe "Trie" do
  describe "Node" do
    it "matches the root route" do
      t = Trie::Node.new
      dummy_handler = ->(ctx : HTTP::Server::Context, params : Hash(String, String)) { }

      t.add_route("/", dummy_handler)

      result = t.search("/")
      result.node.should_not be_nil
      result.params.should be_empty
    end

    it "adds and searches exact routes" do
      t = Trie::Node.new
      dummy_handler = ->(ctx : HTTP::Server::Context, params : Hash(String, String)) { }

      t.add_route("/hello", dummy_handler)
      t.add_route("/hi", dummy_handler)
      t.add_route("/hi/user", dummy_handler)

      result = t.search("/hello")
      result.node.should_not be_nil
      result.params.should be_empty

      result = t.search("/hi")
      result.node.should_not be_nil
      result.params.should be_empty

      result = t.search("/hi/user")
      result.node.should_not be_nil
      result.params.should be_empty
    end

    it "matches routes with single parameter" do
      t = Trie::Node.new
      dummy_handler = ->(ctx : HTTP::Server::Context, params : Hash(String, String)) { }

      t.add_route("/users/:id", dummy_handler)

      result = t.search("/users/42")
      result.node.should_not be_nil
      result.params["id"].should eq("42")

      result = t.search("/users/john")
      result.node.should_not be_nil
      result.params["id"].should eq("john")
    end

    it "matches routes with multiple parameters" do
      t = Trie::Node.new
      dummy_handler = ->(ctx : HTTP::Server::Context, params : Hash(String, String)) { }

      t.add_route("/api/posts/:post_id/comments/:comment_id", dummy_handler)

      result = t.search("/api/posts/42/comments/7")
      result.node.should_not be_nil
      result.params["post_id"].should eq("42")
      result.params["comment_id"].should eq("7")

      result = t.search("/api/posts/hello-world/comments/99")
      result.node.should_not be_nil
      result.params["post_id"].should eq("hello-world")
      result.params["comment_id"].should eq("99")
    end

    it "returns nil for non-existent routes" do
      t = Trie::Node.new
      dummy_handler = ->(ctx : HTTP::Server::Context, params : Hash(String, String)) { }

      t.add_route("/hello", dummy_handler)

      result = t.search("/notfound")
      result.node.should be_nil
    end

    it "prioritizes exact matches over parameter matches" do
      t = Trie::Node.new
      dummy_handler1 = ->(ctx : HTTP::Server::Context, params : Hash(String, String)) {
        ctx.response.print "exact"
      }
      dummy_handler2 = ->(ctx : HTTP::Server::Context, params : Hash(String, String)) {
        ctx.response.print "param"
      }

      t.add_route("/users/list", dummy_handler1)
      t.add_route("/users/:id", dummy_handler2)

      result = t.search("/users/list")
      result.node.should_not be_nil
      result.params.should be_empty

      result = t.search("/users/123")
      result.node.should_not be_nil
      result.params["id"].should eq("123")
    end

    it "preserves parameter names across sibling dynamic routes" do
      t = Trie::Node.new
      dummy_handler = ->(ctx : HTTP::Server::Context, params : Hash(String, String)) { }

      t.add_route("/users/:id", dummy_handler)
      t.add_route("/users/:name/details", dummy_handler)

      result = t.search("/users/alice")
      result.node.should_not be_nil
      result.params["id"].should eq("alice")

      result = t.search("/users/bob/details")
      result.node.should_not be_nil
      result.params["name"].should eq("bob")
    end

    it "matches routes with trailing slashes" do
      t = Trie::Node.new
      dummy_handler = ->(ctx : HTTP::Server::Context, params : Hash(String, String)) { }

      t.add_route("/users/:id", dummy_handler)
      t.add_route("/reports/daily", dummy_handler)

      result = t.search("/users/42/")
      result.node.should_not be_nil
      result.params["id"].should eq("42")

      result = t.search("/reports/daily/")
      result.node.should_not be_nil
      result.params.should be_empty
    end

    it "does not match paths with extra segments" do
      t = Trie::Node.new
      dummy_handler = ->(ctx : HTTP::Server::Context, params : Hash(String, String)) { }

      t.add_route("/users/:id", dummy_handler)
      t.add_route("/reports/daily", dummy_handler)

      t.search("/users/42/details").node.should be_nil
      t.search("/reports/daily/archive").node.should be_nil
    end

    it "normalizes repeated slashes in paths" do
      t = Trie::Node.new
      dummy_handler = ->(ctx : HTTP::Server::Context, params : Hash(String, String)) { }

      t.add_route("/users/:id", dummy_handler)
      t.add_route("/reports/daily", dummy_handler)

      result = t.search("//users//42//")
      result.node.should_not be_nil
      result.params["id"].should eq("42")

      result = t.search("//reports///daily")
      result.node.should_not be_nil
      result.params.should be_empty
    end

    it "prioritizes exact top-level routes over parameter routes" do
      t = Trie::Node.new
      dummy_handler = ->(ctx : HTTP::Server::Context, params : Hash(String, String)) { }

      t.add_route("/:page", dummy_handler)
      t.add_route("/about", dummy_handler)

      result = t.search("/about")
      result.node.should_not be_nil
      result.params.should be_empty

      result = t.search("/contact")
      result.node.should_not be_nil
      result.params["page"].should eq("contact")
    end

    it "prioritizes exact nested routes over parameter routes at the same depth" do
      t = Trie::Node.new
      dummy_handler = ->(ctx : HTTP::Server::Context, params : Hash(String, String)) { }

      t.add_route("/files/:id/edit", dummy_handler)
      t.add_route("/files/new/edit", dummy_handler)

      result = t.search("/files/new/edit")
      result.node.should_not be_nil
      result.params.should be_empty

      result = t.search("/files/123/edit")
      result.node.should_not be_nil
      result.params["id"].should eq("123")
    end

    it "backtracks across multiple parameter children at the same depth" do
      t = Trie::Node.new
      dummy_handler = ->(ctx : HTTP::Server::Context, params : Hash(String, String)) { }

      t.add_route("/users/:id/profile", dummy_handler)
      t.add_route("/users/:name/settings", dummy_handler)

      result = t.search("/users/alice/settings")
      result.node.should_not be_nil
      result.params["name"].should eq("alice")

      result = t.search("/users/42/profile")
      result.node.should_not be_nil
      result.params["id"].should eq("42")
    end
  end
end

describe "LF::DI" do
  it "registers and resolves singleton beans" do
    TestCounterService.reset
    context = LF::DI::AnnotationApplicationContext.new

    context.add_bean(name: "counter", type: TestCounterService) do |_ctx|
      TestCounterService.new
    end

    first = context.get_bean("counter", TestCounterService)
    second = context.get_bean("counter", TestCounterService)

    first.should be(second)
    first.id.should eq(1)
  end

  it "creates a new instance for prototype beans" do
    TestCounterService.reset
    context = LF::DI::AnnotationApplicationContext.new

    context.add_bean(name: "counter", scope: "prototype", type: TestCounterService) do |_ctx|
      TestCounterService.new
    end

    first = context.get_bean("counter", TestCounterService)
    second = context.get_bean("counter", TestCounterService)

    first.should_not be(second)
    first.id.should eq(1)
    second.id.should eq(2)
  end

  it "resolves request-scoped beans from a parent context" do
    context = LF::DI::AnnotationApplicationContext.new

    context.add_bean(name: "greeting", scope: "request", type: TestGreetingService) do |_ctx|
      TestGreetingService.new("from parent")
    end

    child = context.enter_scope("request")
    bean = child.get_bean("greeting", TestGreetingService)

    bean.message.should eq("from parent")
  end

  it "does not allow child contexts to register beans" do
    context = LF::DI::AnnotationApplicationContext.new
    child = context.enter_scope("request")

    expect_raises(LF::DI::ChildContextMutationError, "Child context can not add beans") do
      child.add_bean(name: "greeting", type: TestGreetingService) do |_ctx|
        TestGreetingService.new("nope")
      end
    end
  end

  it "clears cached instances on exit for child contexts" do
    TestCounterService.reset
    context = LF::DI::AnnotationApplicationContext.new

    context.add_bean(name: "counter", scope: "request", type: TestCounterService) do |_ctx|
      TestCounterService.new
    end

    child = context.enter_scope("request")
    first = child.get_bean("counter", TestCounterService)
    second = child.get_bean("counter", TestCounterService)
    second.should be(first)

    child.exit

    third = child.get_bean("counter", TestCounterService)
    third.should_not be(first)
    third.id.should eq(2)
  end

  it "raises when a bean is missing" do
    context = LF::DI::AnnotationApplicationContext.new

    expect_raises(LF::DI::BeanNotFoundError, "Bean not found: name=missing, type=TestGreetingService") do
      context.get_bean("missing", TestGreetingService)
    end
  end

  it "registers bean factories from ApplicationConfig" do
    TestCounterService.reset
    context = LF::DI::AnnotationApplicationContext.new

    context.register(TestConfigWithBeans.new)

    greeting = context.get_bean("greeting_service", TestGreetingService)
    counter = context.get_bean("custom_counter", TestCounterService)

    greeting.message.should eq("hello")
    counter.id.should eq(1)
  end

  it "resolves bean factory dependencies from ApplicationConfig" do
    context = LF::DI::AnnotationApplicationContext.new

    context.register(TestDependentConfig.new)

    context.get_bean("decorated_message", String).should eq("hello, world")
  end

  it "falls back to resolving bean factory dependencies by type when name lookup misses" do
    context = LF::DI::AnnotationApplicationContext.new

    context.register(TestTypeFallbackConfig.new)

    context.get_bean("decorated_message", String).should eq("fallback, world")
  end

  it "prefers name-based bean resolution over type fallback" do
    context = LF::DI::AnnotationApplicationContext.new

    context.register(TestNamePreferredConfig.new)

    context.get_bean("decorated_message", String).should eq("named")
  end

  it "falls back to type-based resolution when name lookup finds the wrong type" do
    context = LF::DI::AnnotationApplicationContext.new

    context.register(TestTypeMismatchFallbackConfig.new)

    context.get_bean("decorated_message", String).should eq("backup")
  end

  it "allows prototype beans to be resolved from a different child scope" do
    TestCounterService.reset
    context = LF::DI::AnnotationApplicationContext.new

    context.add_bean(name: "counter", scope: "prototype", type: TestCounterService) do |_ctx|
      TestCounterService.new
    end

    child = context.enter_scope("request")
    first = child.get_bean("counter", TestCounterService)
    second = child.get_bean("counter", TestCounterService)

    first.should_not be(second)
    first.id.should eq(1)
    second.id.should eq(2)
  end

  it "raises on scope mismatch for non-prototype beans" do
    context = LF::DI::AnnotationApplicationContext.new

    context.add_bean(name: "greeting", scope: "request", type: TestGreetingService) do |_ctx|
      TestGreetingService.new("scoped")
    end

    child = context.enter_scope("session")

    expect_raises(LF::DI::ScopeMismatchError, "Scope mismatch: name=greeting, bean_scope=request, caller_scope=session") do
      child.get_bean("greeting", TestGreetingService)
    end
  end

  it "does not allow entering a singleton child scope" do
    context = LF::DI::AnnotationApplicationContext.new

    expect_raises(LF::DI::InvalidChildScopeError, "Singleton scope is not allowed for child contexts") do
      context.enter_scope("singleton")
    end
  end

  it "supports resolving beans through to_t" do
    context = LF::DI::AnnotationApplicationContext.new

    context.add_bean(name: "greeting", type: TestGreetingService) do |_ctx|
      TestGreetingService.new("typed")
    end

    context.to_t("greeting", TestGreetingService).message.should eq("typed")
  end

  it "raises on duplicate bean names" do
    context = LF::DI::AnnotationApplicationContext.new

    context.add_bean(name: "greeting", type: TestGreetingService) do |_ctx|
      TestGreetingService.new("first")
    end

    expect_raises(LF::DI::DuplicateBeanError, "Bean already registered: name=greeting") do
      context.add_bean(name: "greeting", type: TestGreetingService) do |_ctx|
        TestGreetingService.new("second")
      end
    end
  end

  it "raises on bean type mismatch" do
    context = LF::DI::AnnotationApplicationContext.new

    context.add_bean(name: "greeting", type: TestGreetingService) do |_ctx|
      TestGreetingService.new("hello")
    end

    expect_raises(LF::DI::BeanTypeMismatchError, "Bean type mismatch: name=greeting, expected=String") do
      context.get_bean("greeting", String)
    end
  end

  it "raises when type fallback finds multiple matching beans" do
    context = LF::DI::AnnotationApplicationContext.new

    context.register(TestAmbiguousTypeFallbackConfig.new)

    expect_raises(LF::DI::AmbiguousBeanError, "Ambiguous beans for type TestGreetingService: primary_greeting, secondary_greeting") do
      context.get_bean("decorated_message", String)
    end
  end

  it "tracks ownership metadata for root-owned singleton instances" do
    context = LF::DI::AnnotationApplicationContext.new

    context.add_bean(name: "greeting", type: TestGreetingService) do |_ctx|
      TestGreetingService.new("root")
    end

    instance = context.get_bean_instance("greeting", TestGreetingService)
    instance.owner_scope.should eq("singleton")
    instance.owner_context_id.should eq(context.object_id)
  end

  it "tracks ownership metadata for child-owned scoped instances" do
    context = LF::DI::AnnotationApplicationContext.new

    context.add_bean(name: "greeting", scope: "request", type: TestGreetingService) do |_ctx|
      TestGreetingService.new("request")
    end

    child = context.enter_scope("request")
    instance = child.get_bean_instance("greeting", TestGreetingService)

    instance.owner_scope.should eq("request")
    instance.owner_context_id.should eq(child.object_id)
  end

  it "defines lifecycle-specific DI error types" do
    init_error = LF::DI::BeanInitializationError.new("bean_name", "BeanType", "request", "boom")
    destroy_error = LF::DI::BeanDestructionError.new("destroy failed: 2 errors")

    init_error.should be_a(LF::DI::Error)
    destroy_error.should be_a(LF::DI::Error)
    init_error.message.not_nil!.should contain("phase=init")
  end

  it "allows beans to opt into lifecycle callback interfaces" do
    bean = TestLifecycleBean.new
    bean.after_properties_set
    bean.destroy

    bean.init_called.should be_true
    bean.destroy_called.should be_true
  end

  it "invokes init callback exactly once for singleton beans" do
    TestInitCounterBean.reset
    context = LF::DI::AnnotationApplicationContext.new

    context.add_bean(name: "init_singleton", type: TestInitCounterBean) do |_ctx|
      TestInitCounterBean.new
    end

    first = context.get_bean("init_singleton", TestInitCounterBean)
    second = context.get_bean("init_singleton", TestInitCounterBean)

    first.should be(second)
    TestInitCounterBean.init_calls.should eq(1)
  end

  it "invokes init callback for every prototype instance creation" do
    TestInitCounterBean.reset
    context = LF::DI::AnnotationApplicationContext.new

    context.add_bean(name: "init_prototype", scope: "prototype", type: TestInitCounterBean) do |_ctx|
      TestInitCounterBean.new
    end

    context.get_bean("init_prototype", TestInitCounterBean)
    context.get_bean("init_prototype", TestInitCounterBean)

    TestInitCounterBean.init_calls.should eq(2)
  end

  it "raises BeanInitializationError and does not cache instance when init callback fails" do
    TestFailingInitBean.reset
    context = LF::DI::AnnotationApplicationContext.new

    context.add_bean(name: "failing_init", type: TestFailingInitBean) do |_ctx|
      TestFailingInitBean.new
    end

    expect_raises(LF::DI::BeanInitializationError, "phase=init, bean_name=failing_init") do
      context.get_bean("failing_init", TestFailingInitBean)
    end

    expect_raises(LF::DI::BeanInitializationError, "phase=init, bean_name=failing_init") do
      context.get_bean("failing_init", TestFailingInitBean)
    end

    TestFailingInitBean.instances.should eq(2)
  end

  it "destroys child-owned disposable instances on child exit" do
    TestDisposableCounterBean.reset
    context = LF::DI::AnnotationApplicationContext.new

    context.add_bean(name: "disposable_request", scope: "request", type: TestDisposableCounterBean) do |_ctx|
      TestDisposableCounterBean.new
    end

    child = context.enter_scope("request")
    child.get_bean("disposable_request", TestDisposableCounterBean)

    child.exit

    TestDisposableCounterBean.destroy_calls.should eq(1)
  end

  it "does not destroy root-owned singleton disposable instances on child exit" do
    TestDisposableCounterBean.reset
    context = LF::DI::AnnotationApplicationContext.new

    context.add_bean(name: "disposable_singleton", type: TestDisposableCounterBean) do |_ctx|
      TestDisposableCounterBean.new
    end

    root_instance = context.get_bean("disposable_singleton", TestDisposableCounterBean)
    child = context.enter_scope("request")
    child_instance = child.get_bean("disposable_singleton", TestDisposableCounterBean)

    child_instance.should be(root_instance)

    child.exit

    TestDisposableCounterBean.destroy_calls.should eq(0)
  end

  it "destroys root-owned singleton disposable instances on shutdown" do
    TestDisposableCounterBean.reset
    context = LF::DI::AnnotationApplicationContext.new

    context.add_bean(name: "root_disposable_singleton", type: TestDisposableCounterBean) do |_ctx|
      TestDisposableCounterBean.new
    end

    context.get_bean("root_disposable_singleton", TestDisposableCounterBean)
    context.shutdown

    TestDisposableCounterBean.destroy_calls.should eq(1)
  end

  it "aggregates destroy failures on shutdown as BeanDestructionError" do
    context = LF::DI::AnnotationApplicationContext.new

    context.add_bean(name: "failing_disposable", type: TestFailingDisposableBean) do |_ctx|
      TestFailingDisposableBean.new
    end

    context.get_bean("failing_disposable", TestFailingDisposableBean)

    expect_raises(LF::DI::BeanDestructionError, "phase=destroy") do
      context.shutdown
    end
  end

  it "destroys root-owned disposable instances in reverse creation order on shutdown" do
    TestOrderedDisposableBean.reset
    context = LF::DI::AnnotationApplicationContext.new

    context.add_bean(name: "first", type: TestOrderedDisposableBean) do |_ctx|
      TestOrderedDisposableBean.new("first")
    end
    context.add_bean(name: "second", type: TestOrderedDisposableBean) do |_ctx|
      TestOrderedDisposableBean.new("second")
    end

    context.get_bean("first", TestOrderedDisposableBean)
    context.get_bean("second", TestOrderedDisposableBean)

    context.shutdown

    TestOrderedDisposableBean.destroy_order.should eq(["second", "first"])
  end

  it "destroys child-owned disposable instances in reverse creation order on exit" do
    TestOrderedDisposableBean.reset
    context = LF::DI::AnnotationApplicationContext.new

    context.add_bean(name: "first", scope: "request", type: TestOrderedDisposableBean) do |_ctx|
      TestOrderedDisposableBean.new("first")
    end
    context.add_bean(name: "second", scope: "request", type: TestOrderedDisposableBean) do |_ctx|
      TestOrderedDisposableBean.new("second")
    end

    child = context.enter_scope("request")
    child.get_bean("first", TestOrderedDisposableBean)
    child.get_bean("second", TestOrderedDisposableBean)

    child.exit

    TestOrderedDisposableBean.destroy_order.should eq(["second", "first"])
  end
end

describe "LF::DI::AutowiredApplicationConfig" do
  it "registers annotated services as beans" do
    context = LF::DI::AnnotationApplicationContext.new

    context.register(LF::DI::AutowiredApplicationConfig.new)

    leaf = context.get_bean("auto_leaf_service", AutoLeafService)

    leaf.value.should eq("leaf")
  end

  it "resolves constructor dependencies between annotated services" do
    context = LF::DI::AnnotationApplicationContext.new

    context.register(LF::DI::AutowiredApplicationConfig.new)

    parent = context.get_bean("auto_parent_service", AutoParentService)

    parent.value.should eq("parent->leaf")
    parent.auto_leaf_service.should be(context.get_bean("auto_leaf_service", AutoLeafService))
  end

  it "resolves multi-level constructor dependencies" do
    context = LF::DI::AnnotationApplicationContext.new

    context.register(LF::DI::AutowiredApplicationConfig.new)

    top = context.get_bean("auto_top_service", AutoTopService)

    top.value.should eq("parent->leaf|middle->leaf")
    top.auto_parent_service.should be(context.get_bean("auto_parent_service", AutoParentService))
    top.auto_middle_service.should be(context.get_bean("auto_middle_service", AutoMiddleService))
  end

  it "resolves services with multiple constructor arguments" do
    context = LF::DI::AnnotationApplicationContext.new

    context.register(LF::DI::AutowiredApplicationConfig.new)

    top = context.get_bean("auto_top_service", AutoTopService)

    top.auto_parent_service.auto_leaf_service.should be(context.get_bean("auto_leaf_service", AutoLeafService))
    top.auto_middle_service.auto_leaf_service.should be(context.get_bean("auto_leaf_service", AutoLeafService))
  end

  it "falls back to type-based resolution when constructor argument names do not match bean names" do
    context = LF::DI::AnnotationApplicationContext.new

    context.register(LF::DI::AutowiredApplicationConfig.new)

    context.get_bean("auto_mismatched_arg_service", AutoMismatchedArgService).value.should eq("leaf")
  end

  it "raises on snake_case bean name collisions between annotated services" do
    source = <<-CRYSTAL
      require "../src/opal"

      @[LF::DI::Service]
      class AutoURLService
      end

      @[LF::DI::Service]
      class AutoUrlService
      end

      context = LF::DI::AnnotationApplicationContext.new

      begin
        context.register(LF::DI::AutowiredApplicationConfig.new)
        puts "NO_ERROR"
        exit 1
      rescue e : LF::DI::DuplicateBeanError
        puts e.class
        puts e.message
      end
    CRYSTAL

    path = "/home/mike/opal/spec/tmp_autowired_collision_#{UUID.random}.cr"
    File.write(path, source)
    output = IO::Memory.new
    status = Process.run("crystal", ["run", path], output: output, error: output)
    File.delete(path) if File.exists?(path)

    status.success?.should be_true
    output.to_s.should contain("LF::DI::DuplicateBeanError")
    output.to_s.should contain("Bean already registered: name=auto_url_service")
  end

  it "invokes lifecycle init callbacks for autowired services in constructor graph" do
    AutoLifecycleLeafService.reset
    AutoLifecycleParentService.reset
    context = LF::DI::AnnotationApplicationContext.new

    context.register(LF::DI::AutowiredApplicationConfig.new)
    context.get_bean("auto_lifecycle_parent_service", AutoLifecycleParentService)

    AutoLifecycleLeafService.init_calls.should eq(1)
    AutoLifecycleParentService.init_calls.should eq(1)
  end

  it "invokes lifecycle destroy callbacks for autowired singletons on shutdown in reverse order" do
    AutoLifecycleLeafService.reset
    AutoLifecycleParentService.reset
    context = LF::DI::AnnotationApplicationContext.new

    context.register(LF::DI::AutowiredApplicationConfig.new)
    context.get_bean("auto_lifecycle_parent_service", AutoLifecycleParentService)
    context.shutdown

    AutoLifecycleParentService.destroy_calls.should eq(1)
    AutoLifecycleLeafService.destroy_calls.should eq(1)
    AutoLifecycleLeafService.lifecycle_trace.should eq(["parent", "leaf"])
  end
end

describe "LF::Router" do
  it "routes the root path correctly" do
    router = LF::Router.new

    router.get("/") do |ctx, _params|
      ctx.response.content_type = "text/plain"
      ctx.response.print "root"
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    router.call(context)
    response.close

    response.status.should eq(HTTP::Status::OK)
    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("root")
  end

  it "routes GET requests correctly" do
    router = LF::Router.new

    router.get("/hello") do |ctx, _params|
      ctx.response.content_type = "text/plain"
      ctx.response.print "Hello World!"
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/hello")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    router.call(context)
    response.close

    result_output = io.to_s
    body = result_output.split("\r\n\r\n", 2)[1]
    body.should eq("Hello World!")
    response.status.should eq(HTTP::Status::OK)
  end

  it "extracts route parameters" do
    router = LF::Router.new

    router.get("/users/:id") do |ctx, params|
      ctx.response.content_type = "text/plain"
      ctx.response.print "User ID: #{params["id"]}"
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/users/123")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    router.call(context)
    response.close

    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("User ID: 123")
  end

  it "extracts multiple parameters" do
    router = LF::Router.new

    router.get("/api/posts/:post_id/comments/:comment_id") do |ctx, params|
      ctx.response.content_type = "text/plain"
      ctx.response.print "Post #{params["post_id"]}, Comment #{params["comment_id"]}"
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/api/posts/42/comments/7")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    router.call(context)
    response.close

    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("Post 42, Comment 7")
  end

  it "supports different HTTP methods on same path" do
    router = LF::Router.new

    router.get("/data") do |ctx, _params|
      ctx.response.print "GET data"
    end

    router.post("/data") do |ctx, _params|
      ctx.response.print "POST data"
    end

    # Test GET
    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/data")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)
    router.call(context)
    response.close
    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("GET data")

    # Test POST
    io = IO::Memory.new
    request = HTTP::Request.new("POST", "/data")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)
    router.call(context)
    response.close
    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("POST data")
  end

  it "supports registering multiple methods with add" do
    router = LF::Router.new

    router.add("/bulk", Set{"GET", "POST"}) do |ctx, _params|
      ctx.response.print ctx.request.method
    end

    ["GET", "POST"].each do |method|
      io = IO::Memory.new
      request = HTTP::Request.new(method, "/bulk")
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      router.call(context)
      response.close

      response.status.should eq(HTTP::Status::OK)
      body = io.to_s.split("\r\n\r\n", 2)[1]
      body.should eq(method)
    end
  end

  it "supports multiple methods on the root path" do
    router = LF::Router.new

    router.get("/") do |ctx, _params|
      ctx.response.print "GET root"
    end

    router.post("/") do |ctx, _params|
      ctx.response.print "POST root"
    end

    [
      {"GET", "GET root"},
      {"POST", "POST root"},
    ].each do |method, expected_body|
      io = IO::Memory.new
      request = HTTP::Request.new(method, "/")
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      router.call(context)
      response.close

      response.status.should eq(HTTP::Status::OK)
      body = io.to_s.split("\r\n\r\n", 2)[1]
      body.should eq(expected_body)
    end
  end

  it "returns 405 for wrong method on parameterized routes" do
    router = LF::Router.new

    router.post("/users/:id") do |ctx, _params|
      ctx.response.print "updated"
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/users/123")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    router.call(context)
    response.close

    response.status.should eq(HTTP::Status::METHOD_NOT_ALLOWED)
    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("Method Not Allowed")
  end

  it "returns 405 for wrong method on the root path" do
    router = LF::Router.new

    router.post("/") do |ctx, _params|
      ctx.response.print "root post"
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    router.call(context)
    response.close

    response.status.should eq(HTTP::Status::METHOD_NOT_ALLOWED)
    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("Method Not Allowed")
  end

  it "matches routes with trailing slashes" do
    router = LF::Router.new

    router.get("/users/:id") do |ctx, params|
      ctx.response.print "User #{params["id"]}"
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/users/123/")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    router.call(context)
    response.close

    response.status.should eq(HTTP::Status::OK)
    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("User 123")
  end

  it "matches routes regardless of query string contents" do
    router = LF::Router.new

    router.get("/users/:id") do |ctx, params|
      ctx.response.print "User #{params["id"]}"
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/users/123?active=true&sort=asc")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    router.call(context)
    response.close

    response.status.should eq(HTTP::Status::OK)
    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("User 123")
  end

  it "matches routes with repeated slashes in the request path" do
    router = LF::Router.new

    router.get("/users/:id") do |ctx, params|
      ctx.response.print "User #{params["id"]}"
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "//users//123//")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    router.call(context)
    response.close

    response.status.should eq(HTTP::Status::OK)
    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("User 123")
  end

  it "prioritizes exact routes over parameterized routes for the same prefix" do
    router = LF::Router.new

    router.get("/users/list") do |ctx, _params|
      ctx.response.print "exact"
    end

    router.get("/users/:id") do |ctx, params|
      ctx.response.print "param #{params["id"]}"
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/users/list")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    router.call(context)
    response.close

    response.status.should eq(HTTP::Status::OK)
    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("exact")
  end

  it "prioritizes exact top-level routes over parameterized routes" do
    router = LF::Router.new

    router.get("/:page") do |ctx, params|
      ctx.response.print "param #{params["page"]}"
    end

    router.get("/about") do |ctx, _params|
      ctx.response.print "exact"
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/about")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    router.call(context)
    response.close

    response.status.should eq(HTTP::Status::OK)
    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("exact")
  end

  it "prioritizes exact nested routes over parameterized routes" do
    router = LF::Router.new

    router.get("/files/:id/edit") do |ctx, params|
      ctx.response.print "param #{params["id"]}"
    end

    router.get("/files/new/edit") do |ctx, _params|
      ctx.response.print "exact"
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/files/new/edit")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    router.call(context)
    response.close

    response.status.should eq(HTTP::Status::OK)
    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("exact")
  end

  it "backtracks across multiple parameterized routes at the same depth" do
    router = LF::Router.new

    router.get("/users/:id/profile") do |ctx, params|
      ctx.response.print "profile #{params["id"]}"
    end

    router.get("/users/:name/settings") do |ctx, params|
      ctx.response.print "settings #{params["name"]}"
    end

    [
      {"/users/42/profile", "profile 42"},
      {"/users/alice/settings", "settings alice"},
    ].each do |path, expected_body|
      io = IO::Memory.new
      request = HTTP::Request.new("GET", path)
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)

      router.call(context)
      response.close

      response.status.should eq(HTTP::Status::OK)
      body = io.to_s.split("\r\n\r\n", 2)[1]
      body.should eq(expected_body)
    end
  end

  it "returns 404 when the path has extra segments" do
    router = LF::Router.new

    router.get("/users/:id") do |ctx, _params|
      ctx.response.print "user"
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/users/123/details")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    router.call(context)
    response.close

    response.status.should eq(HTTP::Status::NOT_FOUND)
    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("Not Found")
  end

  it "returns 404 for non-existent routes" do
    router = LF::Router.new

    router.get("/hello") do |ctx, _params|
      ctx.response.print "Hello"
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/notfound")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    router.call(context)
    response.close

    response.status.should eq(HTTP::Status::NOT_FOUND)
  end

  it "returns 405 for wrong HTTP method" do
    router = LF::Router.new

    router.post("/data") do |ctx, _params|
      ctx.response.print "POST only"
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/data")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    router.call(context)
    response.close

    response.status.should eq(HTTP::Status::METHOD_NOT_ALLOWED)
  end

  it "supports all HTTP method convenience methods" do
    router = LF::Router.new

    router.get("/get") { |ctx, _| ctx.response.print "GET" }
    router.post("/post") { |ctx, _| ctx.response.print "POST" }
    router.put("/put") { |ctx, _| ctx.response.print "PUT" }
    router.delete("/delete") { |ctx, _| ctx.response.print "DELETE" }
    router.patch("/patch") { |ctx, _| ctx.response.print "PATCH" }

    methods = ["GET", "POST", "PUT", "DELETE", "PATCH"]
    methods.each do |method|
      io = IO::Memory.new
      request = HTTP::Request.new(method, "/#{method.downcase}")
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)
      router.call(context)
      response.close
      body = io.to_s.split("\r\n\r\n", 2)[1]
      body.should eq(method)
    end
  end
end

describe "LF::LFApi" do
  it "works as HTTP::Handler" do
    app = LF::LFApi.new do |router|
      router.get("/hello") do |ctx, _params|
        ctx.response.content_type = "text/plain"
        ctx.response.print "Hello from Opal!"
      end
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/hello")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    app.call(context)
    response.close

    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("Hello from Opal!")
  end

  it "handles JSON responses" do
    app = LF::LFApi.new do |router|
      router.get("/json") do |ctx, _params|
        ctx.response.content_type = "application/json"
        JsonModel.new(1, "John").to_json(ctx.response)
      end
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/json")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    app.call(context)
    response.close

    result_output = io.to_s
    body = if result_output.includes?("\r\n\r\n")
      result_output.split("\r\n\r\n", 2)[1]
    else
      result_output
    end

    # Just check the body contains the expected JSON structure
    body.should contain("\"id\"")
    body.should contain("\"name\"")
    body.should contain("John")
  end

  it "returns 400 for BadRequest" do
    app = LF::LFApi.new do |router|
      router.get("/bad") do
        raise LF::BadRequest.new("bad input")
      end
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/bad")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    app.call(context)
    response.close

    response.status.should eq(HTTP::Status::BAD_REQUEST)
    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("bad input")
  end

  it "returns 404 for NotFound" do
    app = LF::LFApi.new do |router|
      router.get("/missing") do
        raise LF::NotFound.new("missing")
      end
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/missing")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    app.call(context)
    response.close

    response.status.should eq(HTTP::Status::NOT_FOUND)
    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("missing")
  end

  it "returns 500 for unexpected errors" do
    app = LF::LFApi.new do |router|
      router.get("/boom") do
        raise "boom"
      end
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/boom")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    app.call(context)
    response.close

    response.status.should eq(HTTP::Status::INTERNAL_SERVER_ERROR)
    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("Internal Server Error")
  end
end

describe "LF::APIRoute" do
  it "returns 500 when DI context is not initialized (missing middleware)" do
    # Create API route without DatabaseInjector middleware
    app = LF::LFApi.new do |router|
      TestResourceForDI.new.setup_routes(router)
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/test")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)
    # Note: context.state is nil here (no middleware set it)

    app.call(context)
    response.close

    response.status.should eq(HTTP::Status::INTERNAL_SERVER_ERROR)
    body = io.to_s.split("\r\n\r\n", 2)[1]
    body.should eq("DI context not initialized")
  end

  it "renders JSONResponse return values" do
    app = LF::LFApi.new do |router|
      TestResourceJsonResponse.new.setup_routes(router)
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/json-response")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)

    app.call(context)
    response.close

    response.status.should eq(HTTP::Status::OK)
    parsed = HTTP::Client::Response.from_io(IO::Memory.new(io.to_s))
    payload = JSON.parse(parsed.body)
    payload["id"].as_i.should eq(1)
    payload["name"].as_s.should eq("ok")
  end
end

describe "LF Parameter Binding and Type Coercion" do
  describe "Hash#to_t" do
    it "converts to Int32 successfully" do
      params = {"id" => "42"}
      result = params.to_t("id", Int32)
      result.should eq(42)
    end

    it "raises BadRequest for invalid Int32" do
      params = {"id" => "abc"}
      expect_raises(LF::BadRequest, "Invalid value for parameter 'id': expected Int32") do
        params.to_t("id", Int32)
      end
    end

    it "converts to Int64 successfully" do
      params = {"big_id" => "9223372036854775807"}
      result = params.to_t("big_id", Int64)
      result.should eq(9223372036854775807_i64)
    end

    it "raises BadRequest for invalid Int64" do
      params = {"big_id" => "not_a_number"}
      expect_raises(LF::BadRequest, "Invalid value for parameter 'big_id': expected Int64") do
        params.to_t("big_id", Int64)
      end
    end

    it "converts to Float32 successfully" do
      params = {"price" => "19.99"}
      result = params.to_t("price", Float32).as(Float32)
      result.should be_close(19.99_f32, 0.01)
    end

    it "raises BadRequest for invalid Float32" do
      params = {"price" => "not_a_float"}
      expect_raises(LF::BadRequest, "Invalid value for parameter 'price': expected Float32") do
        params.to_t("price", Float32)
      end
    end

    it "converts to Float64 successfully" do
      params = {"precise" => "3.141592653589793"}
      result = params.to_t("precise", Float64).as(Float64)
      result.should be_close(3.141592653589793, 0.000001)
    end

    it "raises BadRequest for invalid Float64" do
      params = {"precise" => "xyz"}
      expect_raises(LF::BadRequest, "Invalid value for parameter 'precise': expected Float64") do
        params.to_t("precise", Float64)
      end
    end

    it "converts to Bool successfully with 'true'" do
      params = {"active" => "true"}
      result = params.to_t("active", Bool)
      result.should eq(true)
    end

    it "converts to Bool successfully with 'false'" do
      params = {"active" => "false"}
      result = params.to_t("active", Bool)
      result.should eq(false)
    end

    it "converts to Bool successfully with '1'" do
      params = {"active" => "1"}
      result = params.to_t("active", Bool)
      result.should eq(true)
    end

    it "converts to Bool successfully with '0'" do
      params = {"active" => "0"}
      result = params.to_t("active", Bool)
      result.should eq(false)
    end

    it "converts to Bool successfully with 'yes'" do
      params = {"active" => "yes"}
      result = params.to_t("active", Bool)
      result.should eq(true)
    end

    it "converts to Bool successfully with 'no'" do
      params = {"active" => "no"}
      result = params.to_t("active", Bool)
      result.should eq(false)
    end

    it "raises BadRequest for invalid Bool" do
      params = {"active" => "maybe"}
      expect_raises(LF::BadRequest, "Invalid value for parameter 'active': expected Bool") do
        params.to_t("active", Bool)
      end
    end

    it "converts to UUID successfully" do
      params = {"request_id" => "550e8400-e29b-41d4-a716-446655440000"}
      result = params.to_t("request_id", UUID)
      result.should eq(UUID.new("550e8400-e29b-41d4-a716-446655440000"))
    end

    it "raises BadRequest for invalid UUID" do
      params = {"request_id" => "not-a-uuid"}
      expect_raises(LF::BadRequest, "Invalid value for parameter 'request_id': expected UUID") do
        params.to_t("request_id", UUID)
      end
    end

    it "converts to String successfully" do
      params = {"name" => "John Doe"}
      result = params.to_t("name", String)
      result.should eq("John Doe")
    end

    it "raises BadRequest for missing parameter" do
      params = {} of String => String
      expect_raises(LF::BadRequest, "Missing required parameter 'id'") do
        params.to_t("id", Int32)
      end
    end
  end

  describe "APIRoute parameter binding" do
    it "returns 200 for valid Int32 parameter" do
      app = LF::LFApi.new do |router|
        TestAPIWithParams.new.setup_routes(router)
      end

      io = IO::Memory.new
      request = HTTP::Request.new("GET", "/users/123")
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)
      context.state = LF::DI::AnnotationApplicationContext.new

      app.call(context)
      response.close

      response.status.should eq(HTTP::Status::OK)
      body = io.to_s.split("\r\n\r\n", 2)[1]
      body.should eq("User 123")
    end

    it "returns 400 for invalid Int32 parameter" do
      app = LF::LFApi.new do |router|
        TestAPIWithParams.new.setup_routes(router)
      end

      io = IO::Memory.new
      request = HTTP::Request.new("GET", "/users/abc")
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)
      context.state = LF::DI::AnnotationApplicationContext.new

      app.call(context)
      response.close

      response.status.should eq(HTTP::Status::BAD_REQUEST)
      body = io.to_s.split("\r\n\r\n", 2)[1]
      body.should eq("Invalid value for parameter 'id': expected Int32")
    end

    it "returns 200 for valid Int64 parameter" do
      app = LF::LFApi.new do |router|
        TestAPIWithParams.new.setup_routes(router)
      end

      io = IO::Memory.new
      request = HTTP::Request.new("GET", "/items/9223372036854775807")
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)
      context.state = LF::DI::AnnotationApplicationContext.new

      app.call(context)
      response.close

      response.status.should eq(HTTP::Status::OK)
      body = io.to_s.split("\r\n\r\n", 2)[1]
      body.should eq("Item 9223372036854775807")
    end

    it "returns 200 for valid UUID parameter" do
      app = LF::LFApi.new do |router|
        TestAPIWithParams.new.setup_routes(router)
      end

      io = IO::Memory.new
      request = HTTP::Request.new("GET", "/products/550e8400-e29b-41d4-a716-446655440000")
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)
      context.state = LF::DI::AnnotationApplicationContext.new

      app.call(context)
      response.close

      response.status.should eq(HTTP::Status::OK)
      body = io.to_s.split("\r\n\r\n", 2)[1]
      body.should eq("Product 550e8400-e29b-41d4-a716-446655440000")
    end

    it "returns 400 for invalid UUID parameter" do
      app = LF::LFApi.new do |router|
        TestAPIWithParams.new.setup_routes(router)
      end

      io = IO::Memory.new
      request = HTTP::Request.new("GET", "/products/not-a-uuid")
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)
      context.state = LF::DI::AnnotationApplicationContext.new

      app.call(context)
      response.close

      response.status.should eq(HTTP::Status::BAD_REQUEST)
      body = io.to_s.split("\r\n\r\n", 2)[1]
      body.should eq("Invalid value for parameter 'product_id': expected UUID")
    end

    it "returns 200 for valid Bool parameter (true)" do
      app = LF::LFApi.new do |router|
        TestAPIWithParams.new.setup_routes(router)
      end

      io = IO::Memory.new
      request = HTTP::Request.new("GET", "/settings/notifications?enabled=true")
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)
      context.state = LF::DI::AnnotationApplicationContext.new

      app.call(context)
      response.close

      response.status.should eq(HTTP::Status::OK)
      body = io.to_s.split("\r\n\r\n", 2)[1]
      body.should eq("Setting notifications is true")
    end

    it "returns 200 for valid Bool parameter (false)" do
      app = LF::LFApi.new do |router|
        TestAPIWithParams.new.setup_routes(router)
      end

      io = IO::Memory.new
      request = HTTP::Request.new("GET", "/settings/notifications?enabled=false")
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)
      context.state = LF::DI::AnnotationApplicationContext.new

      app.call(context)
      response.close

      response.status.should eq(HTTP::Status::OK)
      body = io.to_s.split("\r\n\r\n", 2)[1]
      body.should eq("Setting notifications is false")
    end

    it "returns 400 for invalid Bool parameter" do
      app = LF::LFApi.new do |router|
        TestAPIWithParams.new.setup_routes(router)
      end

      io = IO::Memory.new
      request = HTTP::Request.new("GET", "/settings/notifications?enabled=maybe")
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)
      context.state = LF::DI::AnnotationApplicationContext.new

      app.call(context)
      response.close

      response.status.should eq(HTTP::Status::BAD_REQUEST)
      body = io.to_s.split("\r\n\r\n", 2)[1]
      body.should eq("Invalid value for parameter 'enabled': expected Bool")
    end

    it "returns 400 for missing required parameter" do
      app = LF::LFApi.new do |router|
        TestAPIWithParams.new.setup_routes(router)
      end

      io = IO::Memory.new
      request = HTTP::Request.new("GET", "/settings/notifications")
      response = HTTP::Server::Response.new(io)
      context = HTTP::Server::Context.new(request, response)
      context.state = LF::DI::AnnotationApplicationContext.new

      app.call(context)
      response.close

      response.status.should eq(HTTP::Status::BAD_REQUEST)
      body = io.to_s.split("\r\n\r\n", 2)[1]
      body.should eq("Missing required parameter 'enabled'")
    end
  end
end
