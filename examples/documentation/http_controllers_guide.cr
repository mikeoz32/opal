require "opal"

# --8<-- [start:binding]
class ProjectView
  include JSON::Serializable

  getter id : String
  getter request_id : String?

  def initialize(id : UUID, @request_id : String?)
    @id = id.to_s
  end
end

class ProjectsApi
  include LF::HTTP::Controller

  @[LF::HTTP::Controller::Get("/projects/:id")]
  def show(id : UUID, request : HTTP::Request) : ProjectView
    ProjectView.new(id, request.headers["X-Request-Id"]?)
  end
end

# --8<-- [end:binding]

# --8<-- [start:policies]
@[LF::DI::Service]
class AuthenticatedGuard < LF::HTTP::Guard
  def can_activate(context : LF::HTTP::ExecutionContext) : Bool
    context.request.headers.has_key?("Authorization")
  end
end

@[LF::DI::Service]
class TrimStrings < LF::HTTP::StringPipe
  def transform_string(
    value : String,
    metadata : LF::HTTP::ArgumentMetadata,
    context : LF::HTTP::ExecutionContext,
  ) : String
    value.strip
  end
end

@[LF::DI::Service]
class RequestTiming < LF::HTTP::Interceptor
  def intercept(
    context : LF::HTTP::ExecutionContext,
    call_next : LF::HTTP::CallHandler,
  ) : LF::HTTP::Response
    started_at = Time.instant
    response = call_next.call
    elapsed = Time.instant - started_at
    context.response.headers["Server-Timing"] = "app;dur=#{elapsed.total_milliseconds}"
    response
  end
end

class ProjectError < Exception
end

@[LF::DI::Service]
class ApiErrorFilter < LF::HTTP::ExceptionFilter
  handles ProjectError

  def catch_typed(
    exception : ProjectError,
    context : LF::HTTP::ExecutionContext,
  ) : LF::HTTP::Response
    context.response.status = HTTP::Status::UNPROCESSABLE_ENTITY
    LF::HTTP::TextResponse.create(exception.message || "Invalid project")
  end
end

@[LF::HTTP::UseGuards(AuthenticatedGuard)]
@[LF::HTTP::UseInterceptors(RequestTiming)]
class ProjectCommandsApi
  include LF::HTTP::Controller

  @[LF::HTTP::Controller::Post("/projects")]
  @[LF::HTTP::UseFilters(ApiErrorFilter)]
  def create(@[LF::HTTP::UsePipes(TrimStrings)] name : String) : ProjectView
    raise ProjectError.new("name cannot be empty") if name.empty?
    ProjectView.new(UUID.random, nil)
  end
end

root = LF::DI::DefaultContainer.new
root.register(LF::DI::ServiceConfiguration.new)

app = LF::HTTP::App.new do |router|
  ProjectsApi.setup_routes(router, root)
  ProjectCommandsApi.setup_routes(router, root)
end
# --8<-- [end:policies]
