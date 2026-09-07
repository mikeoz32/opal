module LF::Microservices
  alias ClientReplyOutcome = EncodedDelivery | ReplyProtocolFailure | RPCOutcomeUnknownError

  # Synchronous, fiber-safe RPC orchestration over a running client transport.
  # It owns typed envelope construction and response validation, but never
  # retries an accepted publication automatically.
  class RPCClient
    DEFAULT_TIMEOUT = 5.seconds
    IDLE_POLL       = 1.millisecond

    getter transport : ClientTransport
    getter codec : JSONCodec
    getter max_pending : Int32

    @pending = {} of UUID => RPCTarget
    @completed = {} of UUID => ClientReplyOutcome
    @lock = Mutex.new
    @closed = false

    def initialize(
      @transport : ClientTransport,
      @codec : JSONCodec = JSONCodec.new,
      max_pending : Int = 1_024,
      @clock : Proc(Time) = -> { Microservices.utc_now },
    )
      unless max_pending > 0 && max_pending <= Int32::MAX
        raise TransportCapacityError.new("max_pending must be a positive 32-bit integer")
      end
      @max_pending = max_pending.to_i32
      unless transport.status.running?
        raise TransportStateError.new("RPCClient requires a running client transport")
      end
    end

    def pending_count : Int32
      @lock.synchronize { @pending.size }
    end

    def closed? : Bool
      @lock.synchronize { @closed }
    end

    def call(
      target : RPCTarget,
      request : Request,
      response_type : Response.class,
      *,
      timeout : Time::Span = DEFAULT_TIMEOUT,
      headers : Hash(String, JSON::Any) = {} of String => JSON::Any,
      causation_id : UUID? = nil,
    ) : Response forall Request, Response
      raise ArgumentError.new("RPC timeout must be positive") unless timeout > 0.seconds

      correlation_id = UUID.random
      registered = false
      accepted = false
      monotonic_deadline = Time.instant + timeout

      begin
        register(target, correlation_id)
        registered = true
        created_at = @clock.call
        deadline_at = created_at + timeout
        envelope = RPCRequestEnvelope.new(
          UUID.random,
          target.service,
          target.method,
          target.schema_version,
          created_at,
          deadline_at,
          correlation_id,
          transport.reply_to,
          causation_id: causation_id,
          headers: headers,
          payload: JSON.parse(request.to_json),
          limits: codec.limits,
        )
        publication = Publication.new(
          envelope.message_id,
          target.routing_key,
          codec.encode_request(envelope),
          mandatory: true,
          correlation_id: correlation_id,
          reply_to: envelope.reply_to,
          expires_at: deadline_at,
          content_type: codec.profile.rpc_content_type,
          limits: codec.limits,
        )
        receipt = transport.publish_rpc(target, publication)
        unless receipt.message_id == publication.message_id && receipt.routed
          raise RPCRejectedError.new(
            "RPC publication was not routed",
            target,
            correlation_id,
          )
        end
        accepted = true

        delivery = await_reply(target, correlation_id, monotonic_deadline)
        decode_response(delivery, target, correlation_id, response_type)
      rescue error : RPCClientError
        raise error
      rescue error : TransportIndeterminateError
        raise RPCOutcomeUnknownError.new(
          "RPC outcome is unknown after transport failure",
          target,
          correlation_id,
          error,
        )
      rescue error : TransportRejectedError | TransportUnroutableError | TransportCapacityError
        if accepted
          raise RPCOutcomeUnknownError.new(
            "RPC outcome is unknown after acceptance",
            target,
            correlation_id,
            error,
          )
        end
        raise RPCRejectedError.new(
          "RPC publication was rejected before acceptance",
          target,
          correlation_id,
          error,
        )
      rescue error : TransportError
        if accepted
          raise RPCOutcomeUnknownError.new(
            "RPC outcome is unknown after transport failure",
            target,
            correlation_id,
            error,
          )
        end
        raise RPCTransportError.new(
          "RPC transport failed before acceptance",
          target,
          correlation_id,
          error,
        )
      rescue error : WireError | JSON::ParseException
        raise RPCProtocolError.new(
          "RPC payload or envelope is not protocol-compatible",
          target,
          correlation_id,
          error,
        )
      ensure
        if registered
          unregister(correlation_id)
          transport.cancel_pending(correlation_id)
        end
      end
    end

    # Replaces the ephemeral reply route and fails every affected accepted call
    # as outcome-unknown. The requests are deliberately not republished.
    def reconnect : Array(UUID)
      canceled = transport.reconnect
      mark_outcome_unknown(canceled, "RPC outcome is unknown after reply transport reconnect")
      canceled
    end

    # Fails outstanding calls as outcome-unknown, then closes the owned
    # transport. Calling `close` again is harmless.
    def close : Nil
      targets = @lock.synchronize do
        return if @closed
        @closed = true
        @pending.dup
      end
      mark_outcome_unknown(targets.keys, "RPC outcome is unknown because the client closed")
      transport.close
    end

    private def register(target : RPCTarget, correlation_id : UUID) : Nil
      @lock.synchronize do
        raise TransportStateError.new("RPCClient is closed") if @closed
        unless transport.status.running?
          raise TransportStateError.new("RPC client transport is not running")
        end
        if @pending.size >= max_pending
          raise TransportCapacityError.new("RPCClient pending capacity is full")
        end
        @pending[correlation_id] = target
      end
    end

    private def unregister(correlation_id : UUID) : Nil
      @lock.synchronize do
        @pending.delete(correlation_id)
        @completed.delete(correlation_id)
      end
    end

    private def await_reply(
      target : RPCTarget,
      correlation_id : UUID,
      deadline : Time::Instant,
    ) : EncodedDelivery
      loop do
        if delivery = completed_reply(target, correlation_id)
          return delivery
        end

        pump_reply
        if delivery = completed_reply(target, correlation_id)
          return delivery
        end

        if Time.instant >= deadline
          raise RPCTimeoutError.new(
            "RPC deadline elapsed; the remote outcome may still have occurred",
            target,
            correlation_id,
          )
        end

        remaining = deadline - Time.instant
        sleep(remaining < IDLE_POLL ? remaining : IDLE_POLL) if remaining > 0.seconds
      end
    end

    private def completed_reply(target : RPCTarget, correlation_id : UUID) : EncodedDelivery?
      outcome = take_completed(correlation_id)
      return nil unless outcome

      case outcome
      when EncodedDelivery
        outcome
      when ReplyProtocolFailure
        raise RPCProtocolError.new(outcome.reason, target, correlation_id)
      when RPCOutcomeUnknownError
        raise outcome
      end
    end

    private def pump_reply : Nil
      outcome = transport.next_reply?
      return unless outcome

      correlation_id = outcome.correlation_id
      unless correlation_id
        raise TransportCorrelationError.new("reply delivery has no correlation_id")
      end
      @lock.synchronize do
        if @pending.has_key?(correlation_id) && !@completed.has_key?(correlation_id)
          @completed[correlation_id] = outcome
        end
      end
    end

    private def take_completed(correlation_id : UUID) : ClientReplyOutcome?
      @lock.synchronize { @completed.delete(correlation_id) }
    end

    private def mark_outcome_unknown(correlations : Enumerable(UUID), message : String) : Nil
      @lock.synchronize do
        correlations.each do |correlation_id|
          if target = @pending[correlation_id]?
            @completed[correlation_id] ||= RPCOutcomeUnknownError.new(
              message,
              target,
              correlation_id,
            )
          end
        end
      end
    end

    private def decode_response(
      delivery : EncodedDelivery,
      target : RPCTarget,
      correlation_id : UUID,
      response_type : Response.class,
    ) : Response forall Response
      if content_type = delivery.content_type
        unless content_type == codec.profile.rpc_content_type
          raise RPCProtocolError.new(
            "RPC reply content_type is not compatible with the protocol profile",
            target,
            correlation_id,
          )
        end
      end
      unless delivery.routing_key == transport.reply_to.value
        raise RPCProtocolError.new("RPC reply route does not match the client", target, correlation_id)
      end
      unless delivery.correlation_id == correlation_id
        raise RPCProtocolError.new("RPC reply delivery correlation does not match", target, correlation_id)
      end

      response = codec.decode_response(delivery.body)
      unless response.message_id == delivery.message_id
        raise RPCProtocolError.new("RPC reply message_id does not match its envelope", target, correlation_id)
      end
      unless response.correlation_id == correlation_id
        raise RPCProtocolError.new("RPC response correlation does not match", target, correlation_id)
      end
      if remote_error = response.error
        raise RPCRemoteError.new(remote_error, target, correlation_id)
      end

      result = response.result.not_nil!
      {% if Response == Nil %}
        unless result.raw.nil?
          raise RPCProtocolError.new("RPC response must contain a null result", target, correlation_id)
        end
        nil
      {% else %}
        begin
          Response.from_json(result.to_json)
        rescue error : JSON::ParseException
          raise RPCProtocolError.new(
            "RPC response does not match #{Response}",
            target,
            correlation_id,
            error,
          )
        end
      {% end %}
    rescue error : RPCClientError
      raise error
    rescue error : WireError
      raise RPCProtocolError.new(
        "RPC response envelope is not protocol-compatible",
        target,
        correlation_id,
        error,
      )
    end
  end

  # Adds a fixed service identity and compile-time typed RPC methods to a
  # small application-owned client class.
  module TypedServiceClient
    macro included
      getter rpc_client : LF::Microservices::RPCClient

      def initialize(@rpc_client : LF::Microservices::RPCClient)
      end
    end

    macro service(namespace, name, contract_version)
      {% unless namespace.is_a?(StringLiteral) && name.is_a?(StringLiteral) %}
        {% raise "Typed service identity namespace and name must be string literals" %}
      {% end %}
      {% unless contract_version.is_a?(NumberLiteral) %}
        {% raise "Typed service contract_version must be an integer literal" %}
      {% end %}

      SERVICE = LF::Microservices::ServiceIdentity.new(
        {{ namespace }},
        {{ name }},
        {{ contract_version }}
      )

      def service : LF::Microservices::ServiceIdentity
        SERVICE
      end
    end

    macro rpc(name, request_type, response_type, method = nil, schema_version = 1)
      {% unless @type.constants.map(&.stringify).includes?("SERVICE") %}
        {% raise "Typed RPC clients must declare service before rpc methods" %}
      {% end %}
      {% request = request_type.resolve %}
      {% response = response_type.resolve %}
      {% remote_method = method.is_a?(NilLiteral) ? name.stringify : method %}
      {% unless name.is_a?(Call) || name.is_a?(MacroId) || name.is_a?(StringLiteral) %}
        {% raise "Typed RPC method name must be an identifier" %}
      {% end %}
      {% unless remote_method.is_a?(StringLiteral) %}
        {% raise "Typed RPC remote method must be a string literal" %}
      {% end %}
      {% unless schema_version.is_a?(NumberLiteral) %}
        {% raise "Typed RPC schema_version must be an integer literal" %}
      {% end %}
      {% unless request.ancestors.includes?(JSON::Serializable) %}
        {% raise "Typed RPC request #{request} must include JSON::Serializable" %}
      {% end %}
      {% unless response == Nil || response.ancestors.includes?(JSON::Serializable) %}
        {% raise "Typed RPC response #{response} must include JSON::Serializable or be Nil" %}
      {% end %}
      {% if @type.methods.any? { |existing| existing.name.stringify == name.id.stringify } %}
        {% raise "Duplicate typed RPC method #{name.id} on #{@type}" %}
      {% end %}

      def {{ name.id }}(
        request : {{ request }},
        *,
        timeout : Time::Span = LF::Microservices::RPCClient::DEFAULT_TIMEOUT,
        headers : Hash(String, JSON::Any) = {} of String => JSON::Any,
        causation_id : UUID? = nil,
      ) : {{ response }}
        rpc_client.call(
          LF::Microservices::RPCTarget.new(service, {{ remote_method }}, {{ schema_version }}),
          request,
          {{ response }},
          timeout: timeout,
          headers: headers,
          causation_id: causation_id,
        )
      end
    end
  end
end
