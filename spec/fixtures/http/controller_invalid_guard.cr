require "../../../src/opal"

class NotAGuard
end

@[LF::HTTP::UseGuards(NotAGuard)]
class InvalidGuardController
  include LF::HTTP::Controller

  @[LF::HTTP::Controller::Get("/invalid")]
  def show : String
    "invalid"
  end
end

root = LF::DI::DefaultContainer.new
router = LF::HTTP::Router.new
InvalidGuardController.setup_routes(router, root)
