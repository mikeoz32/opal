require "../../../src/opal/microservices"

struct PlainClientRequest
end

struct ValidClientResponse
  include JSON::Serializable
end

class InvalidRequestClient
  include LF::Microservices::TypedServiceClient

  service "shop", "catalog", 1
  rpc find, PlainClientRequest, ValidClientResponse, "find", 1
end
