require "../../../src/opal/microservices"

struct DuplicateClientRequest
  include JSON::Serializable
end

struct DuplicateClientResponse
  include JSON::Serializable
end

class DuplicateRPCClient
  include LF::Microservices::TypedServiceClient

  service "shop", "catalog", 1
  rpc find, DuplicateClientRequest, DuplicateClientResponse, "find", 1
  rpc find, DuplicateClientRequest, DuplicateClientResponse, "lookup", 1
end
