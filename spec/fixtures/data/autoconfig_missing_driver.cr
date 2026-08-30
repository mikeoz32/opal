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
rescue error : LF::Data::AutoConfig::ConfigurationError
  raise "missing driver cause was not preserved" unless error.cause.is_a?(ArgumentError)
  raise "configuration error leaked the database URL" if error.message.try(&.includes?("password"))
  raise "runtime was not closed after installation failure" unless runtime.closed?
end
