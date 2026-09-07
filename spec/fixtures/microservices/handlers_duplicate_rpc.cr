require "../../../src/opal/microservices"

struct DuplicateRequest
  include JSON::Serializable
end

struct DuplicateResponse
  include JSON::Serializable
end

class FirstDuplicateController
  include LF::Microservices::MessageController

  @[LF::Microservices::RPC(method: "find", schema_version: 1)]
  def find(request : DuplicateRequest) : DuplicateResponse
    DuplicateResponse.new
  end
end

class SecondDuplicateController
  include LF::Microservices::MessageController

  @[LF::Microservices::RPC(method: "find", schema_version: 1)]
  def other(request : DuplicateRequest) : DuplicateResponse
    DuplicateResponse.new
  end
end

service = LF::Microservices::ServiceIdentity.new("shop", "catalog", 1)
LF::Microservices.compile_handlers(
  service,
  FirstDuplicateController,
  SecondDuplicateController
)
