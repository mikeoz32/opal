require "../../../src/opal/autoconfig/microservices/rabbitmq"

@[LF::Application]
@[LF::AutoConfig::Microservices]
class EmptyMicroservicesApplication
end

typeof(EmptyMicroservicesApplication.bootstrap_microservice)
