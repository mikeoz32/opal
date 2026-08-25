require "../../../src/opal"

class InvalidRouteService
end

class InvalidRouteController
  include LF::HTTP::Controller

  @[LF::HTTP::Controller::Get("/invalid")]
  def show(service : InvalidRouteService)
    service.to_s
  end
end

root = LF::DI::DefaultContainer.new
router = LF::HTTP::Router.new
InvalidRouteController.setup_routes(router, root)
