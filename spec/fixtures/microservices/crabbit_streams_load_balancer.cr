require "../../../src/opal/autoconfig/microservices/crabbit_streams"

alias MS = LF::Microservices

class LoadBalancerFixtureStream
  include MS::StreamTopology
  stream "load-balancer-fixture"
end

@[LF::Application]
@[LF::AutoConfig::CrabbitStreams(
  topologies: [LoadBalancerFixtureStream],
)]
class LoadBalancerFixtureApplication
end

path = "/tmp/opal-crabbit-load-balancer-#{Process.pid}.yml"
File.write(path, <<-YAML)
  microservices:
    streams:
      load_balancer: true
  YAML

container = LF::DI::DefaultContainer.new
container.add_bean(name: "config_service", type: LF::ConfigService) do |_scope|
  LF::ConfigService.new(path)
end
container.resolve("config_service", LF::ConfigService)
context = LF::ApplicationContext.new(container)
captured = false
factory = ->(_uri : String, load_balancer : Bool) do
  captured = load_balancer
  raise "stop after environment factory"
  Crabbit::Environment.new
end
extension = LF::Microservices::CrabbitStreamsAutoConfig::Extension.new(factory)
begin
  extension.configure(context)
rescue error : Exception
  raise error unless error.message == "stop after environment factory"
end
raise "load_balancer was not forwarded to Crabbit" unless captured
container.shutdown
File.delete(path)
