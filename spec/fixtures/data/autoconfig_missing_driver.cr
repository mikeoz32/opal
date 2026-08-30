require "../../../src/opal"
require "../../../src/opal/autoconfig/data"

path = ARGV[0]
root = LF::DI::DefaultContainer.new
root.add_bean(name: "config_service", type: LF::ConfigService) do |_scope|
  LF::ConfigService.new(path)
end
root.resolve(LF::ConfigService)
runtime = LF::ApplicationRuntime.new(root)

begin
  runtime.install(LF::Data::AutoConfig::Extension.new)
  raise "Data autoconfiguration unexpectedly succeeded without sqlite3"
rescue error : ArgumentError
  raise "driver error was wrapped" if error.is_a?(LF::Data::AutoConfig::ConfigurationError)
  raise "driver error leaked the database URL" if error.message.try(&.includes?("password"))
  raise "runtime was not closed after installation failure" unless runtime.closed?
end
