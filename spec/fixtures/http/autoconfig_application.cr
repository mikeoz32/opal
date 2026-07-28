require "../../../src/opal"
require "../../../src/opal/autoconfig/http"

@[LF::Application]
@[LF::AutoConfig::HTTP]
class ValidHTTPApplication
end

runtime = ValidHTTPApplication.bootstrap
runtime.shutdown

typeof(ValidHTTPApplication.run_http)
