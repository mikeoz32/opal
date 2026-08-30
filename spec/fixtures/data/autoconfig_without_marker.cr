require "../../../src/opal"
require "../../../src/opal/autoconfig/data"

@[LF::Application]
class DataAutoconfigUnmarkedApplication
end

runtime = DataAutoconfigUnmarkedApplication.bootstrap
runtime.shutdown
