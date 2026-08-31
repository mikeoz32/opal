require "http/server"
require "json"
require "../di"
require "./di_integration"
require "./errors"
require "./response"

module LF::HTTP
  # Applies the listed policies to every controller in an HTTP application, a
  # controller, an action, or an action parameter depending on the annotation
  # target.
  annotation UseGuards
  end

  annotation UsePipes
  end

  annotation UseInterceptors
  end

  annotation UseFilters
  end

  enum ArgumentSource
    Path
    Query
    Body
  end

  struct ArgumentMetadata
    getter name : String
    getter target_type : String
    getter source : ArgumentSource

    def initialize(@name, @target_type, @source)
    end
  end

  struct ExecutionContext
    getter http_context : ::HTTP::Server::Context
    getter route_params : Hash(String, String)
    getter controller : String
    getter action : String

    def initialize(
      @http_context,
      @route_params,
      @controller,
      @action,
      @request_override : ::HTTP::Request? = nil,
    )
    end

    def request : ::HTTP::Request
      @request_override || @http_context.request
    end

    def response : ::HTTP::Server::Response
      @http_context.response
    end

    def dependency_scope : LF::DI::Container
      @http_context.dependency_scope || raise LF::HTTP::InternalServerError.new("DI context not initialized")
    end
  end

  abstract class Guard
    abstract def can_activate(context : ExecutionContext) : Bool
  end

  alias PipeValue = String | JSON::Any

  abstract class Pipe
    abstract def transform(
      value : PipeValue,
      metadata : ArgumentMetadata,
      context : ExecutionContext,
    ) : PipeValue
  end

  # Convenience base for a pipe interested only in path/query string values.
  # JSON body values pass through unchanged.
  abstract class StringPipe < Pipe
    def transform(
      value : PipeValue,
      metadata : ArgumentMetadata,
      context : ExecutionContext,
    ) : PipeValue
      return value unless value.is_a?(String)
      transform_string(value, metadata, context)
    end

    abstract def transform_string(
      value : String,
      metadata : ArgumentMetadata,
      context : ExecutionContext,
    ) : String
  end

  # Convenience base for a pipe interested only in parsed JSON request bodies.
  # Path and query string values pass through unchanged.
  abstract class JSONPipe < Pipe
    def transform(
      value : PipeValue,
      metadata : ArgumentMetadata,
      context : ExecutionContext,
    ) : PipeValue
      return value unless value.is_a?(JSON::Any)
      transform_json(value, metadata, context)
    end

    abstract def transform_json(
      value : JSON::Any,
      metadata : ArgumentMetadata,
      context : ExecutionContext,
    ) : JSON::Any
  end

  alias CallHandler = Proc(Response)

  abstract class Interceptor
    abstract def intercept(context : ExecutionContext, call_next : CallHandler) : Response
  end

  abstract class Filter
    abstract def catch(exception : Exception, context : ExecutionContext) : Response?
  end

  # Base for a typed exception filter. `handles SomeError` generates the
  # type-erased dispatch required by a heterogeneous filter chain.
  abstract class ExceptionFilter < Filter
    macro handles(exception_type)
      def catch(exception : Exception, context : LF::HTTP::ExecutionContext) : LF::HTTP::Response?
        return nil unless exception.is_a?({{ exception_type }})
        catch_typed(exception.as({{ exception_type }}), context)
      end
    end
  end

  module ExecutionPipeline
    def self.apply_pipes(
      value : PipeValue,
      metadata : ArgumentMetadata,
      context : ExecutionContext,
      pipes : Array(Pipe),
    ) : PipeValue
      pipes.reduce(value) do |current, pipe|
        pipe.transform(current, metadata, context)
      end
    end

    def self.intercept(
      context : ExecutionContext,
      interceptors : Array(Interceptor),
      &action : -> Response
    ) : Response
      return yield if interceptors.empty?
      InterceptorChain.new(context, interceptors, action).call
    end

    def self.catch(
      exception : Exception,
      context : ExecutionContext,
      filters : Array(Filter),
    ) : Response?
      filters.each do |filter|
        if response = filter.catch(exception, context)
          return response
        end
      end
      nil
    end

    private class InterceptorChain
      def initialize(
        @context : ExecutionContext,
        @interceptors : Array(Interceptor),
        @action : CallHandler,
      )
      end

      def call(index : Int32 = 0) : Response
        return @action.call if index >= @interceptors.size

        interceptor = @interceptors[index]
        interceptor.intercept(@context, -> { call(index + 1) })
      end
    end
  end
end
