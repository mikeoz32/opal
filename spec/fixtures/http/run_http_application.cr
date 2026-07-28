require "../../../src/opal"
require "../../../src/opal/autoconfig/http"

@[LF::Application]
@[LF::AutoConfig::HTTP]
class RunHTTPApplication
end

RunHTTPApplication.run_http
