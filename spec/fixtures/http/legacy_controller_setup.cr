require "../../../src/opal"

class LegacySetupController
  include LF::HTTP::Controller

  @[LF::HTTP::Controller::Get("/legacy")]
  def show : String
    "legacy"
  end
end

router = LF::HTTP::Router.new
LegacySetupController.new.setup_routes(router)
