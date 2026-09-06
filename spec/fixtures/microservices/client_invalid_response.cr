require "../../../src/opal/microservices"

struct ValidClientRequest
  include JSON::Serializable
end

struct PlainClientResponse
end

class InvalidResponseClient
  include LF::Microservices::TypedServiceClient

  service "shop", "catalog", 1
  rpc find, ValidClientRequest, PlainClientResponse, "find", 1
end
