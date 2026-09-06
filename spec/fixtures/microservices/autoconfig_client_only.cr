require "../../../src/opal/autoconfig/microservices/rabbitmq"

struct ClientOnlyRequest
  include JSON::Serializable
end

struct ClientOnlyResponse
  include JSON::Serializable
end

class ClientOnlyCatalogClient
  include LF::Microservices::TypedServiceClient

  service "shop", "catalog", 1
  rpc find, ClientOnlyRequest, ClientOnlyResponse, "find", 1
end

@[LF::Application]
@[LF::AutoConfig::Microservices(clients: [ClientOnlyCatalogClient])]
class ClientOnlyGatewayApplication
end

typeof(ClientOnlyGatewayApplication.bootstrap_microservice)
