require "../application"

module LF::Microservices
  alias RegistryBuilder = Proc(LF::ApplicationContext, HandlerRegistry)
  alias RPCErrorMapper = Proc(Exception, RemoteRPCErrorData)
  alias EventErrorClassifier = Proc(Exception, SettlementRecommendation)

  class RuntimeConfigurationError < Error
  end

  class DrainTimeoutError < Error
    include LF::ApplicationExtension::StopIncomplete

    def initialize
      super("microservices transport did not drain before the application deadline")
    end
  end

  # Owns one service's inbound transport, handler executor, reply publication,
  # settlement, and application shutdown lifecycle. Transport adapters remain
  # responsible only for broker I/O and the settlement operation itself.
  class ServerRuntime
    include LF::ApplicationExtension

    getter service : ServiceIdentity
    getter transport : ServerTransport
    getter codec : JSONCodec

    @registry : HandlerRegistry?
    @executor : HandlerExecutor?
    @configured = false
    @stopped = false

    def initialize(
      @service : ServiceIdentity,
      @transport : ServerTransport,
      @codec : JSONCodec = JSONCodec.new,
      @instance_id : String? = nil,
      @clock : Proc(Time) = -> { Microservices.utc_now },
      @rpc_error_mapper : RPCErrorMapper = ->(error : Exception) { ServerRuntime.default_rpc_error(error) },
      @event_error_classifier : EventErrorClassifier = ->(error : Exception) { ServerRuntime.default_event_outcome(error) },
      &@registry_builder : RegistryBuilder
    )
      Microservices.validate_alias(instance_id, "instance_id") if instance_id
    end

    def registry : HandlerRegistry
      @registry || raise RuntimeConfigurationError.new("microservices runtime is not configured")
    end

    def configured? : Bool
      @configured
    end

    def stopped? : Bool
      @stopped
    end

    def configure(context : LF::ApplicationContext) : Nil
      if @configured || @stopped || !transport.status.created?
        raise RuntimeConfigurationError.new(
          "microservices configure requires a new runtime and Created transport"
        )
      end

      compiled = @registry_builder.call(context)
      unless compiled.sealed?
        raise RuntimeConfigurationError.new("message handler registry must be sealed")
      end
      validate_service(compiled)

      executor = HandlerExecutor.new(compiled, context)
      @registry = compiled
      @executor = executor
      transport.prepare(
        compiled.rpc_handlers.map(&.target.method),
        subscriptions(compiled),
      )
      transport.start(->(delivery : EncodedDelivery) { dispatch(delivery) })
      @configured = true
    end

    def dispatch(delivery : EncodedDelivery) : SettlementRecommendation
      if delivery.subscription
        dispatch_event(delivery)
      else
        dispatch_rpc(delivery)
      end
    end

    def quiesce(context : LF::ShutdownContext) : Nil
      return if transport.status.closed?

      transport.stop_intake if transport.status.running?
      return unless transport.status.quiescing?

      raise DrainTimeoutError.new unless transport.drain(context.deadline)
    end

    def stop : Nil
      return if @stopped

      if transport.status.in?(TransportStatus::Running, TransportStatus::Quiescing)
        quiesce(LF::ShutdownContext.new(Time.instant + LF::ApplicationRuntime::DEFAULT_SHUTDOWN_TIMEOUT))
      end
      transport.close unless transport.status.closed?
      @stopped = true
    end

    def self.default_rpc_error(error : Exception) : RemoteRPCErrorData
      case error
      when MessageAuthorizationError
        RemoteRPCErrorData.new("permission_denied", "Message authorization failed.")
      when WireDeadlineError
        RemoteRPCErrorData.new("deadline_exceeded", "The RPC deadline has elapsed.")
      when WireError, MessageRejectedError
        RemoteRPCErrorData.new("invalid_request", "The RPC request was rejected.")
      when MessageRetryableError
        RemoteRPCErrorData.new(
          "temporarily_unavailable",
          "The service is temporarily unavailable.",
          retryable: true,
        )
      else
        RemoteRPCErrorData.new("internal_error", "The service could not complete the request.")
      end
    end

    def self.default_event_outcome(error : Exception) : SettlementRecommendation
      error.is_a?(MessageRetryableError) ? SettlementRecommendation::Retry : SettlementRecommendation::Reject
    end

    private def executor : HandlerExecutor
      @executor || raise RuntimeConfigurationError.new("microservices runtime is not configured")
    end

    private def dispatch_rpc(delivery : EncodedDelivery) : SettlementRecommendation
      result = executor.dispatch_rpc(delivery, codec, now: @clock.call)
      publish_response(delivery, result: result)
    rescue error : Exception
      publish_response(delivery, error: @rpc_error_mapper.call(error))
    end

    private def publish_response(
      delivery : EncodedDelivery,
      result : JSON::Any? = nil,
      error : RemoteRPCErrorData? = nil,
    ) : SettlementRecommendation
      correlation_id = delivery.correlation_id || return SettlementRecommendation::Reject
      reply_to = delivery.reply_to || return SettlementRecommendation::Reject
      completed_at = @clock.call
      response = if error
                   RPCResponseEnvelope.failure(
                     UUID.random,
                     correlation_id,
                     completed_at,
                     error,
                     limits: codec.limits,
                   )
                 else
                   RPCResponseEnvelope.success(
                     UUID.random,
                     correlation_id,
                     completed_at,
                     result || JSON::Any.new(nil),
                     limits: codec.limits,
                   )
                 end
      receipt = transport.publish_reply(Publication.new(
        response.message_id,
        reply_to.value,
        codec.encode_response(response),
        mandatory: true,
        correlation_id: correlation_id,
        content_type: codec.profile.rpc_content_type,
        limits: codec.limits,
      ))
      receipt.routed ? SettlementRecommendation::Ack : SettlementRecommendation::Reject
    rescue TransportUnroutableError
      SettlementRecommendation::Reject
    rescue TransportError
      SettlementRecommendation::Retry
    rescue WireError
      SettlementRecommendation::Reject
    end

    private def dispatch_event(delivery : EncodedDelivery) : SettlementRecommendation
      executor.dispatch_event(delivery, codec, now: @clock.call)
      SettlementRecommendation::Ack
    rescue error : Exception
      outcome = @event_error_classifier.call(error)
      if outcome.unsettled?
        raise RuntimeConfigurationError.new("event error classifier must settle the delivery")
      end
      outcome
    end

    private def validate_service(compiled : HandlerRegistry) : Nil
      mismatched = compiled.rpc_handlers.reject { |plan| plan.target.service == service }
      return if mismatched.empty?

      routes = mismatched.map(&.target.routing_key).sort.join(", ")
      raise RuntimeConfigurationError.new(
        "RPC handlers do not belong to service #{service.label}: #{routes}"
      )
    end

    private def subscriptions(compiled : HandlerRegistry) : Array(EventSubscription)
      compiled.event_handlers.map do |plan|
        destination = plan.mode.singleton? ? nil : service
        instance_id = plan.mode.broadcast? ? @instance_id : nil
        EventSubscription.new(
          plan.identity,
          plan.mode,
          plan.subscription,
          destination: destination,
          instance_id: instance_id,
          reliable: plan.reliable,
        )
      end
    end
  end

  # Installs a server runtime while compiling controllers against the same
  # application container that owns every per-message scope.
  macro install_server(runtime, service, transport, *controllers)
    {{ runtime }}.install(
      LF::Microservices::ServerRuntime.new({{ service }}, {{ transport }}) do |application_context|
        LF::Microservices.compile_executable_handlers(
          {{ service }},
          application_context,
          {{ controllers.splat }}
        )
      end
    )
  end
end
