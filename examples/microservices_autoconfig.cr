require "../src/opal/autoconfig/microservices/rabbitmq"

alias MS = LF::Microservices

struct AutoconfigFindProduct
  include JSON::Serializable

  getter sku : String

  def initialize(@sku : String)
  end
end

struct AutoconfigAvailability
  include JSON::Serializable

  getter available : Bool

  def initialize(@available : Bool)
  end
end

class AutoconfigCatalogMessages
  include MS::MessageController

  @[MS::RPC(method: "find", schema_version: 1)]
  def find(request : AutoconfigFindProduct) : AutoconfigAvailability
    AutoconfigAvailability.new(request.sku == "opal-1")
  end
end

class AutoconfigCatalogClient
  include MS::TypedServiceClient

  service "shop", "catalog", 1
  rpc find, AutoconfigFindProduct, AutoconfigAvailability, "find", 1
end

@[LF::Application]
@[LF::AutoConfig::Microservices(
  namespace: "shop",
  service: "catalog",
  contract_version: 1,
  controllers: [AutoconfigCatalogMessages],
  clients: [AutoconfigCatalogClient],
)]
class AutoconfigCatalogApplication
end

AutoconfigCatalogApplication.run_microservice
