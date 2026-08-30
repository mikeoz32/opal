require "../src/opal"

@[LF::DI::Service]
class APIKeyGuard < LF::HTTP::Guard
  def can_activate(context : LF::HTTP::ExecutionContext) : Bool
    context.request.headers["Authorization"]? == "Bearer opal"
  end
end

@[LF::DI::Service]
class TrimPipe < LF::HTTP::StringPipe
  def transform_string(
    value : String,
    metadata : LF::HTTP::ArgumentMetadata,
    context : LF::HTTP::ExecutionContext,
  ) : String
    value.strip
  end
end

@[LF::DI::Service]
class TimingInterceptor < LF::HTTP::Interceptor
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

class GreetingError < Exception
end

@[LF::DI::Service]
class GreetingErrorFilter < LF::HTTP::ExceptionFilter
  handles GreetingError

  def catch_typed(
    exception : GreetingError,
    context : LF::HTTP::ExecutionContext,
  ) : LF::HTTP::Response
    context.response.status = HTTP::Status::UNPROCESSABLE_ENTITY
    LF::HTTP::TextResponse.create(exception.message || "Invalid greeting")
  end
end

@[LF::HTTP::UseGuards(APIKeyGuard)]
@[LF::HTTP::UsePipes(TrimPipe)]
@[LF::HTTP::UseInterceptors(TimingInterceptor)]
@[LF::HTTP::UseFilters(GreetingErrorFilter)]
class HttpPolicies
end

class GreetingController
  include LF::HTTP::Controller

  @[LF::HTTP::Controller::Get("/hello")]
  def show(name : String) : String
    raise GreetingError.new("name cannot be empty") if name.empty?
    "Hello, #{name}!"
  end
end

root = LF::DI::DefaultContainer.new
root.register(LF::DI::ServiceConfiguration.new)

app = LF::HTTP::App.new do |router|
  GreetingController.setup_routes(router, root, HttpPolicies)
end

server = HTTP::Server.new([
  HTTP::LogHandler.new,
  LF::HTTP::DI::RequestScopeHandler.new(root),
  app,
])

address = server.bind_tcp(8082)
puts "Listening on http://#{address}"
puts "curl -H 'Authorization: Bearer opal' 'http://#{address}/hello?name=%20Opal%20'"

begin
  server.listen
ensure
  root.shutdown
end
