require "../../../src/opal"

class FirstBody
  include JSON::Serializable

  getter value : String
end

class SecondBody
  include JSON::Serializable

  getter value : String
end

class MultipleBodyController
  include LF::HTTP::Controller

  @[LF::HTTP::Controller::Post("/invalid")]
  def create(first : FirstBody, second : SecondBody) : String
    first.value + second.value
  end
end

root = LF::DI::DefaultContainer.new
router = LF::HTTP::Router.new
MultipleBodyController.setup_routes(router, root)
