require "../di"
require "../execution"

module LF::Microservices
  # Message policies deliberately use their own annotations and context. They
  # share orchestration with HTTP through LF::Execution, never through a fake
  # HTTP request.
  annotation UseGuards
  end

  annotation UsePipes
  end

  annotation UseInterceptors
  end

  annotation UseFilters
  end

  enum ArgumentSource
    Payload
    Header
    Metadata
  end

  # Position and topology metadata for an event read from a replayable stream.
  # Queue-backed message deliveries leave this value absent.
  struct StreamDeliveryMetadata
    getter topology : String
    getter stream : String
    getter subscription : String
    getter offset : UInt64
    getter timestamp : Time
    getter super_stream : String?

    def initialize(
      @topology : String,
      @stream : String,
      @subscription : String,
      @offset : UInt64,
      @timestamp : Time,
      @super_stream : String? = nil,
    )
      raise MessageConfigurationError.new("stream topology must not be empty") if topology.empty?
      raise MessageConfigurationError.new("stream name must not be empty") if stream.empty?
      raise MessageConfigurationError.new("stream subscription must not be empty") if subscription.empty?
    end
  end

  struct ArgumentMetadata
    getter name : String
    getter target_type : String
    getter source : ArgumentSource

    def initialize(@name : String, @target_type : String, @source : ArgumentSource)
      raise MessageConfigurationError.new("argument name must not be empty") if name.empty?
      raise MessageConfigurationError.new("argument target type must not be empty") if target_type.empty?
    end
  end

  struct ExecutionContext
    getter delivery : EncodedDelivery
    getter dependency_scope : LF::DI::Container
    getter controller : String
    getter action : String
    getter rpc_target : RPCTarget?
    getter event_identity : EventIdentity?
    getter correlation_id : UUID?
    getter causation_id : UUID?
    getter stream_metadata : StreamDeliveryMetadata?
    @headers : Hash(String, JSON::Any)

    def initialize(
      @delivery : EncodedDelivery,
      @dependency_scope : LF::DI::Container,
      @controller : String,
      @action : String,
      @rpc_target : RPCTarget? = nil,
      @event_identity : EventIdentity? = nil,
      headers : Hash(String, JSON::Any) = {} of String => JSON::Any,
      @correlation_id : UUID? = nil,
      @causation_id : UUID? = nil,
      @stream_metadata : StreamDeliveryMetadata? = nil,
    )
      @headers = WireValue.deep_copy(headers)
      raise MessageConfigurationError.new("controller must not be empty") if controller.empty?
      raise MessageConfigurationError.new("action must not be empty") if action.empty?
      if rpc_target.nil? == event_identity.nil?
        raise MessageConfigurationError.new(
          "message execution context requires exactly one RPC target or event identity"
        )
      end
    end

    def rpc? : Bool
      !rpc_target.nil?
    end

    def event? : Bool
      !event_identity.nil?
    end

    def stream? : Bool
      !stream_metadata.nil?
    end

    # Application-owned headers from the decoded JSON envelope. Broker headers
    # remain available separately on `delivery` and are never merged here.
    def headers : Hash(String, JSON::Any)
      WireValue.deep_copy(@headers)
    end
  end

  alias PipeValue = JSON::Any
  alias ExecutionResult = JSON::Any

  abstract class Guard < LF::Execution::Guard(ExecutionContext)
  end

  abstract class Pipe < LF::Execution::Pipe(PipeValue, ArgumentMetadata, ExecutionContext)
  end

  abstract class Interceptor < LF::Execution::Interceptor(ExecutionContext, ExecutionResult)
  end

  abstract class Filter < LF::Execution::Filter(ExecutionContext, ExecutionResult)
  end

  abstract class ExceptionFilter < Filter
    macro handles(exception_type)
      def catch(exception : Exception, context : LF::Microservices::ExecutionContext) : LF::Microservices::ExecutionResult?
        return nil unless exception.is_a?({{ exception_type }})
        catch_typed(exception.as({{ exception_type }}), context)
      end
    end
  end

  module ExecutionPipeline
    extend self

    def authorized?(context : ExecutionContext, guards : Array(Guard)) : Bool
      LF::Execution::Pipeline.authorized?(context, guards)
    end

    def apply_pipes(
      value : PipeValue,
      metadata : ArgumentMetadata,
      context : ExecutionContext,
      pipes : Array(Pipe),
    ) : PipeValue
      LF::Execution::Pipeline.apply_pipes(value, metadata, context, pipes)
    end

    def intercept(
      context : ExecutionContext,
      interceptors : Array(Interceptor),
      &action : -> ExecutionResult
    ) : ExecutionResult
      LF::Execution::Pipeline.intercept(context, interceptors, &action)
    end

    def catch(
      exception : Exception,
      context : ExecutionContext,
      filters : Array(Filter),
    ) : ExecutionResult?
      LF::Execution::Pipeline.catch(exception, context, filters)
    end
  end
end
