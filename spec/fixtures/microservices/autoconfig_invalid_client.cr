require "../../../src/opal/autoconfig/microservices/rabbitmq"

class NotATypedServiceClient
end

@[LF::Application]
@[LF::AutoConfig::Microservices(clients: [NotATypedServiceClient])]
class InvalidClientApplication
end

typeof(InvalidClientApplication.bootstrap_microservice)
