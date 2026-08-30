require "../../../src/opal"
require "../../../src/opal/autoconfig/http"

@[LF::DI::Service]
class ValidHTTPGlobalGuard < LF::HTTP::Guard
  def can_activate(context : LF::HTTP::ExecutionContext) : Bool
    true
  end
end

class ValidHTTPController
  include LF::HTTP::Controller

  @[LF::HTTP::Controller::Get("/valid")]
  def show : String
    "valid"
  end
end

@[LF::Application]
@[LF::AutoConfig::HTTP]
@[LF::HTTP::UseGuards(ValidHTTPGlobalGuard)]
class ValidHTTPApplication
end

runtime = ValidHTTPApplication.bootstrap
runtime.shutdown

typeof(ValidHTTPApplication.run_http)
