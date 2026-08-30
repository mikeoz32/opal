require "../../../src/opal"
require "../../../src/opal/autoconfig/data"
require "sqlite3"

@[LF::Application]
@[LF::AutoConfig::Data]
class DataAutoconfigApplication
end

DataAutoconfigApplication.bootstrap
