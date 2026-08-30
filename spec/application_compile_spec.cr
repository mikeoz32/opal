require "./spec_helper"

private def compile_fixture(path : String) : NamedTuple(status: Process::Status, output: String, error: String)
  output = IO::Memory.new
  error = IO::Memory.new
  cache_dir = ENV.fetch("CRYSTAL_CACHE_DIR", "/tmp/opal-crystal-cache")
  Dir.mkdir_p(cache_dir)

  status = Process.run(
    "crystal",
    ["build", "--no-codegen", path],
    env: {"CRYSTAL_CACHE_DIR" => cache_dir},
    output: output,
    error: error
  )

  {status: status, output: output.to_s, error: error.to_s}
end

describe "application compiler fixtures" do
  it "accepts a valid conditional application autoconfiguration" do
    fixture = File.expand_path(
      "fixtures/application/autoconfiguration_valid.cr",
      __DIR__
    )
    result = compile_fixture(fixture)

    result[:status].success?.should be_true
    result[:error].should eq("")
  end

  it "rejects a non-integer autoconfiguration priority" do
    fixture = File.expand_path(
      "fixtures/application/autoconfiguration_invalid_priority.cr",
      __DIR__
    )
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain(
      "Invalid application autoconfiguration priority for InvalidPriorityExtension: " \
      "expected integer literal"
    )
  end

  it "rejects an explicit nil autoconfiguration priority" do
    fixture = File.expand_path(
      "fixtures/application/autoconfiguration_nil_priority.cr",
      __DIR__
    )
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain(
      "Invalid application autoconfiguration priority for NilPriorityExtension: " \
      "expected integer literal"
    )
  end

  it "rejects an explicit false autoconfiguration priority" do
    fixture = File.expand_path(
      "fixtures/application/autoconfiguration_false_priority.cr",
      __DIR__
    )
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain(
      "Invalid application autoconfiguration priority for FalsePriorityExtension: " \
      "expected integer literal"
    )
  end

  it "requires an enabled_by marker on autoconfiguration descriptors" do
    fixture = File.expand_path(
      "fixtures/application/autoconfiguration_missing_marker.cr",
      __DIR__
    )
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain(
      "Invalid application autoconfiguration enabled_by for MissingMarkerExtension: " \
      "attribute is required"
    )
  end

  it "requires enabled_by to resolve to an existing annotation" do
    fixture = File.expand_path(
      "fixtures/application/autoconfiguration_unknown_marker.cr",
      __DIR__
    )
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain(
      "Invalid application autoconfiguration enabled_by for UnknownMarkerExtension: " \
      "expected annotation type"
    )
  end

  it "rejects a non-annotation enabled_by type" do
    fixture = File.expand_path(
      "fixtures/application/autoconfiguration_non_annotation_marker.cr",
      __DIR__
    )
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain(
      "Invalid application autoconfiguration enabled_by for NonAnnotationMarkerExtension: " \
      "expected annotation type"
    )
  end

  it "requires a zero-argument autoconfiguration constructor" do
    fixture = File.expand_path(
      "fixtures/application/autoconfiguration_requires_arguments.cr",
      __DIR__
    )
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain(
      "Invalid application autoconfiguration constructor for " \
      "RequiresArgumentsExtension: expected zero-argument initialize"
    )
  end

  it "validates an inherited autoconfiguration constructor" do
    fixture = File.expand_path(
      "fixtures/application/autoconfiguration_inherited_constructor.cr",
      __DIR__
    )
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain(
      "Invalid application autoconfiguration constructor for " \
      "InheritedRequiresArgumentsExtension: expected zero-argument initialize"
    )
  end

  it "rejects a typed splat autoconfiguration constructor" do
    fixture = File.expand_path(
      "fixtures/application/autoconfiguration_typed_splat_constructor.cr",
      __DIR__
    )
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain(
      "Invalid application autoconfiguration constructor for " \
      "TypedSplatConstructorExtension: expected zero-argument initialize"
    )
  end

  it "requires an autoconfiguration descriptor to implement ApplicationExtension" do
    fixture = File.expand_path(
      "fixtures/application/autoconfiguration_not_extension.cr",
      __DIR__
    )
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain(
      "Invalid application autoconfiguration type for NotAnApplicationExtension: " \
      "must include LF::ApplicationExtension"
    )
  end

  it "requires a concrete autoconfiguration extension" do
    fixture = File.expand_path(
      "fixtures/application/autoconfiguration_abstract_extension.cr",
      __DIR__
    )
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain(
      "Invalid application autoconfiguration type for AbstractFixtureExtension: " \
      "must be concrete"
    )
  end

  it "keeps standalone DI executables valid without an application marker" do
    fixture = File.expand_path("fixtures/application/standalone_di.cr", __DIR__)
    result = compile_fixture(fixture)

    result[:status].success?.should be_true
    result[:error].should eq("")
  end

  it "rejects multiple application markers" do
    fixture = File.expand_path("fixtures/application/multiple_applications.cr", __DIR__)
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain("Only one @[LF::Application] is allowed per executable")
  end

  it "rejects application classes that require constructor arguments" do
    fixture = File.expand_path("fixtures/application/application_requires_arguments.cr", __DIR__)
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain("wrong number of arguments for 'InvalidApp.new'")
  end

  it "rejects configuration classes that require constructor arguments" do
    fixture = File.expand_path("fixtures/application/configuration_requires_arguments.cr", __DIR__)
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain("wrong number of arguments for 'InvalidConfiguration.new'")
  end

  it "rejects non-integer configuration priorities with an actionable error" do
    fixture = File.expand_path("fixtures/application/invalid_configuration_priority.cr", __DIR__)
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain("Invalid application configuration priority for InvalidPriorityConfiguration")
  end

  it "rejects a floating-point application priority" do
    fixture = File.expand_path("fixtures/application/invalid_application_float_priority.cr", __DIR__)
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain(
      "Invalid application priority for InvalidFloatPriorityApplication: expected Int32"
    )
  end

  it "rejects a floating-point configuration priority" do
    fixture = File.expand_path(
      "fixtures/application/invalid_configuration_float_priority.cr",
      __DIR__
    )
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain(
      "Invalid application configuration priority for " \
      "InvalidFloatPriorityConfiguration: expected Int32"
    )
  end

  it "does not expose the runtime container" do
    fixture = File.expand_path("fixtures/application/runtime_context_access.cr", __DIR__)
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain("undefined method 'context' for LF::ApplicationRuntime")
  end

  it "rejects service injection through controller route arguments" do
    fixture = File.expand_path("fixtures/http/controller_service_argument.cr", __DIR__)
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain("Invalid route argument 'service'")
    result[:error].should contain("inject services through the controller constructor")
  end

  it "does not retain the legacy controller instance setup API" do
    fixture = File.expand_path("fixtures/http/legacy_controller_setup.cr", __DIR__)
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain("undefined method 'setup_routes' for LegacySetupController")
  end

  it "rejects a controller guard that does not implement the guard contract" do
    fixture = File.expand_path("fixtures/http/controller_invalid_guard.cr", __DIR__)
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain(
      "Invalid guard NotAGuard on InvalidGuardController: expected LF::HTTP::Guard"
    )
  end

  it "rejects pipes attached to the raw HTTP request argument" do
    fixture = File.expand_path("fixtures/http/controller_request_pipe.cr", __DIR__)
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain(
      "Invalid pipes on HTTP::Request argument 'request' in RequestPipeController#show"
    )
  end

  it "rejects routes with more than one JSON body argument" do
    fixture = File.expand_path("fixtures/http/controller_multiple_bodies.cr", __DIR__)
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain(
      "Invalid route MultipleBodyController#create: expected at most one JSON body argument"
    )
  end

  it "supports constructor DI inherited from a controller base class" do
    fixture = File.expand_path("fixtures/http/inherited_controller_initializer.cr", __DIR__)
    result = compile_fixture(fixture)

    result[:status].success?.should be_true
    result[:error].should eq("")
  end

  it "rejects HTTP autoconfiguration without an application marker" do
    fixture = File.expand_path("fixtures/http/autoconfig_without_application.cr", __DIR__)
    result = compile_fixture(fixture)

    result[:status].success?.should be_false
    result[:error].should contain("@[LF::AutoConfig::HTTP] requires @[LF::Application] on NotAnApplication")
  end

  it "has no behavior when the optional HTTP file is only required" do
    fixture = File.expand_path("fixtures/http/autoconfig_without_marker.cr", __DIR__)
    result = compile_fixture(fixture)

    result[:status].success?.should be_true
    result[:error].should eq("")
  end

  it "generates run_http only for an annotated application" do
    fixture = File.expand_path("fixtures/http/autoconfig_application.cr", __DIR__)
    result = compile_fixture(fixture)

    result[:status].success?.should be_true
    result[:error].should eq("")
  end
end
