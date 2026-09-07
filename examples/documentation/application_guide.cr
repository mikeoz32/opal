require "opal"
require "opal/autoconfig/http"

@[LF::Application]
@[LF::AutoConfig::HTTP]
class MyApplication
end

MyApplication.run_http
