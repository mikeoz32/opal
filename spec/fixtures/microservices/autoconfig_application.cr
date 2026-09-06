require "../../../src/opal/autoconfig/microservices/rabbitmq"

struct AutoConfigFindProduct
  include JSON::Serializable

  getter sku : String

  def initialize(@sku : String)
  end
end

struct AutoConfigAvailability
  include JSON::Serializable

  getter available : Bool

  def initialize(@available : Bool)
  end
end

class AutoConfigCatalogMessages
  include LF::Microservices::MessageController

  @[LF::Microservices::RPC(method: "find", schema_version: 1)]
  def find(request : AutoConfigFindProduct) : AutoConfigAvailability
    AutoConfigAvailability.new(!request.sku.empty?)
  end
end

class AutoConfigCatalogClient
  include LF::Microservices::TypedServiceClient

  service "shop", "catalog", 1
  rpc find, AutoConfigFindProduct, AutoConfigAvailability, "find", 1
end

@[LF::Application]
@[LF::AutoConfig::Microservices(
  namespace: "shop",
  service: "catalog",
  contract_version: 1,
  controllers: [AutoConfigCatalogMessages],
  clients: [AutoConfigCatalogClient],
)]
class AutoConfigMicroservicesApplication
end

typeof(AutoConfigMicroservicesApplication.bootstrap_microservice)
typeof(AutoConfigMicroservicesApplication.run_microservice)
