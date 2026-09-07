require "../../../src/opal/microservices"

struct PolicyRequest
  include JSON::Serializable
end

struct PolicyResponse
  include JSON::Serializable
end

class NotAMessageGuard
end

@[LF::Microservices::UseGuards(NotAMessageGuard)]
class InvalidPolicyController
  include LF::Microservices::MessageController

  @[LF::Microservices::RPC(method: "find", schema_version: 1)]
  def find(request : PolicyRequest) : PolicyResponse
    PolicyResponse.new
  end
end

service = LF::Microservices::ServiceIdentity.new("shop", "catalog", 1)
LF::Microservices.compile_handlers(service, InvalidPolicyController)
