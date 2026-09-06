require "../../../src/opal/microservices"

struct PlainRequest
end

struct ValidResponse
  include JSON::Serializable
end

class InvalidPayloadController
  include LF::Microservices::MessageController

  @[LF::Microservices::RPC(method: "find", schema_version: 1)]
  def find(request : PlainRequest) : ValidResponse
    ValidResponse.new
  end
end

service = LF::Microservices::ServiceIdentity.new("shop", "catalog", 1)
LF::Microservices.compile_handlers(service, InvalidPayloadController)
