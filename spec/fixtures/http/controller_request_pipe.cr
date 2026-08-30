require "../../../src/opal"

class RequestPipe < LF::HTTP::StringPipe
  def transform_string(
    value : String,
    metadata : LF::HTTP::ArgumentMetadata,
    context : LF::HTTP::ExecutionContext,
  ) : String
    value
  end
end

class RequestPipeController
  include LF::HTTP::Controller

  @[LF::HTTP::Controller::Get("/invalid")]
  def show(@[LF::HTTP::UsePipes(RequestPipe)] request : HTTP::Request) : String
    request.path
  end
end

root = LF::DI::DefaultContainer.new
router = LF::HTTP::Router.new
RequestPipeController.setup_routes(router, root)
