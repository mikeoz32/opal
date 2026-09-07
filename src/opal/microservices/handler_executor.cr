module LF::Microservices
  # Executes already-decoded envelopes through compiled handler plans. All
  # transport/envelope checks happen before a message scope is created.
  class HandlerExecutor
    getter registry : HandlerRegistry

    def initialize(@registry : HandlerRegistry, @scope_provider : LF::DI::ScopeProvider)
      raise HandlerCompilationError.new("handler registry must be sealed") unless registry.sealed?
    end

    def dispatch_rpc(
      delivery : EncodedDelivery,
      codec : JSONCodec = JSONCodec.new,
      now : Time = Time.utc,
    ) : JSON::Any
      validate_content_type(delivery.content_type, codec.profile.rpc_content_type, "RPC")
      envelope = codec.decode_request(delivery.body)
      invoke_rpc(delivery, envelope, now)
    end

    def dispatch_event(
      delivery : EncodedDelivery,
      codec : JSONCodec = JSONCodec.new,
      now : Time = Time.utc,
    ) : JSON::Any
      validate_content_type(delivery.content_type, codec.profile.event_content_type, "event")
      envelope = codec.decode_event(delivery.body)
      invoke_event(delivery, envelope, now)
    end

    def invoke_rpc(
      delivery : EncodedDelivery,
      envelope : RPCRequestEnvelope,
      now : Time = Time.utc,
    ) : JSON::Any
      target = RPCTarget.new(envelope.service, envelope.method, envelope.schema_version)
      validate_common(delivery, envelope.message_id, target.routing_key, now)
      if delivery.correlation_id != envelope.correlation_id
        raise MessageRejectedError.new("delivery correlation_id does not match RPC envelope")
      end
      if delivery.reply_to != envelope.reply_to
        raise MessageRejectedError.new("delivery reply_to does not match RPC envelope")
      end
      if envelope.deadline_at <= now
        raise WireDeadlineError.new("RPC request deadline has elapsed")
      end
      plan = registry.rpc(target.routing_key) || raise MessageRejectedError.new(
        "no RPC handler for route #{target.routing_key}"
      )
      if plan.target.schema_version != envelope.schema_version
        raise MessageRejectedError.new(
          "unsupported RPC schema version #{envelope.schema_version} for #{target.routing_key}"
        )
      end
      invoke_scoped(
        plan,
        delivery,
        envelope.payload,
        envelope.headers,
        envelope.correlation_id,
        envelope.causation_id,
      )
    end

    def invoke_event(
      delivery : EncodedDelivery,
      envelope : EventEnvelope,
      now : Time = Time.utc,
    ) : JSON::Any
      identity = EventIdentity.new(envelope.source, envelope.event, envelope.schema_version)
      validate_common(delivery, envelope.message_id, identity.routing_key, now)
      subscription = delivery.subscription || raise MessageRejectedError.new(
        "event delivery is missing its subscription identity"
      )
      unless subscription.identity == identity
        raise MessageRejectedError.new("delivery subscription does not match event envelope")
      end
      plan_route = "#{identity.source.label}.#{identity.routing_key}.#{subscription.subscription}"
      plan = registry.event(plan_route) || raise MessageRejectedError.new(
        "no event handler for subscription route #{plan_route}"
      )
      invoke_scoped(
        plan,
        delivery,
        envelope.payload,
        envelope.headers,
        envelope.correlation_id,
        envelope.causation_id,
      )
    end

    private def validate_common(
      delivery : EncodedDelivery,
      message_id : UUID,
      routing_key : String,
      now : Time,
    ) : Nil
      WireValue.validate_utc(now, "invocation time")
      if delivery.message_id != message_id
        raise MessageRejectedError.new("delivery message_id does not match envelope")
      end
      if delivery.routing_key != routing_key
        raise MessageRejectedError.new("delivery routing_key does not match envelope")
      end
      raise WireDeadlineError.new("delivery has expired") if delivery.expired?(now)
    end

    private def validate_content_type(actual : String?, expected : String, kind : String) : Nil
      return unless actual
      unless actual == expected
        raise WireDecodingError.new("unsupported #{kind} content_type: #{actual}")
      end
    end

    private def invoke_scoped(
      plan : RPCHandlerPlan | EventHandlerPlan,
      delivery : EncodedDelivery,
      payload : JSON::Any,
      headers : Hash(String, JSON::Any),
      correlation_id : UUID?,
      causation_id : UUID?,
    ) : JSON::Any
      scope : LF::DI::Container? = nil
      body_error : Exception? = nil
      result : JSON::Any? = nil

      begin
        scope = @scope_provider.enter_scope("message")
        context = if plan.is_a?(RPCHandlerPlan)
                    ExecutionContext.new(
                      delivery,
                      scope,
                      plan.controller,
                      plan.action,
                      rpc_target: plan.target,
                      headers: headers,
                      correlation_id: correlation_id,
                      causation_id: causation_id,
                    )
                  else
                    ExecutionContext.new(
                      delivery,
                      scope,
                      plan.controller,
                      plan.action,
                      event_identity: plan.identity,
                      headers: headers,
                      correlation_id: correlation_id,
                      causation_id: causation_id,
                    )
                  end
        result = plan.invoke(scope, context, payload)
      rescue error : Exception
        body_error = error
      ensure
        if current_scope = scope
          begin
            current_scope.exit
          rescue scope_error : Exception
            raise MessageScopeError.new(scope_error, body_error)
          end
        end
      end

      raise body_error.not_nil! if body_error
      result.not_nil!
    end
  end
end
