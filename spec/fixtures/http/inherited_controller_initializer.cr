require "../../../src/opal"

class InheritedControllerDependency
end

class InheritedControllerBase
  def initialize(@dependency : InheritedControllerDependency)
  end
end

class InheritedController < InheritedControllerBase
  include LF::HTTP::Controller

  @[LF::HTTP::Controller::Get("/inherited")]
  def show : String
    @dependency.to_s
  end
end

root = LF::DI::DefaultContainer.new
root.add_bean(name: "dependency", type: InheritedControllerDependency) do |_scope|
  InheritedControllerDependency.new
end
router = LF::HTTP::Router.new
InheritedController.setup_routes(router, root)
