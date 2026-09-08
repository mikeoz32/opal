module LF::Microservices
  # Framework-level confirmation that preserves the event identity while
  # hiding Crabbit's single-stream and super-stream handle distinction.
  class StreamPublishReceipt
    getter message_id : UUID
    getter identity : EventIdentity
    getter topology : String

    def initialize(
      @message_id : UUID,
      @identity : EventIdentity,
      @topology : String,
      @handles : Array(::Crabbit::PublishHandle),
    )
    end

    def await(timeout : Time::Span = 30.seconds) : self
      raise ArgumentError.new("publish timeout must be positive") unless timeout > 0.seconds
      deadline = Time.instant + timeout
      @handles.each do |handle|
        remaining = deadline - Time.instant
        raise StreamPublishError.new(message_id, "confirmation timed out") unless remaining > 0.seconds
        confirmation = handle.await(remaining)
        unless confirmation.confirmed
          error = confirmation.error
          raise StreamPublishError.new(
            message_id,
            error.try(&.message) || "broker rejected publishing id #{confirmation.publishing_id}",
            error,
          )
        end
      end
      self
    rescue error : StreamPublishError
      raise error
    rescue error : Exception
      raise StreamPublishError.new(message_id, error.message || error.class.to_s, error)
    end
  end

  # Typed event publisher backed by RabbitMQ Streams through Crabbit.
  class StreamPublisher
    getter environment : ::Crabbit::Environment
    getter codec : JSONCodec
    getter producer_name : String

    @mutex = Mutex.new
    @producers = {} of String => ::Crabbit::Producer
    @super_producers = {} of String => ::Crabbit::SuperStreamProducer
    @pending = [] of ::Crabbit::PublishHandle
    @accepting = true
    @closed = false

    def initialize(
      @environment : ::Crabbit::Environment,
      @producer_name : String,
      @codec : JSONCodec = JSONCodec.new,
      @producer_options : ::Crabbit::ProducerOptions? = nil,
    )
      raise StreamConfigurationError.new("producer_name must not be empty") if producer_name.empty?
      if configured = producer_options
        unless configured.name
          raise StreamConfigurationError.new(
            "custom producer_options must declare a stable name for broker deduplication",
          )
        end
        unless configured.filter_value_extractor
          raise StreamConfigurationError.new(
            "custom producer_options must declare a filter_value_extractor for stream event filtering",
          )
        end
      end
    end

    def closed? : Bool
      @mutex.synchronize { @closed }
    end

    def publish(
      topology : Topology.class,
      event : Event,
      *,
      routing_key : String? = nil,
      headers : Hash(String, JSON::Any) = {} of String => JSON::Any,
      correlation_id : UUID? = nil,
      causation_id : UUID? = nil,
      message_id : UUID = UUID.random,
    ) : StreamPublishReceipt forall Topology, Event
      {% unless Topology.ancestors.includes?(LF::Microservices::StreamTopology) %}
        {% raise "#{Topology} must include LF::Microservices::StreamTopology" %}
      {% end %}
      {% unless Event.ancestors.includes?(LF::Microservices::StreamEvent) %}
        {% raise "#{Event} must include LF::Microservices::StreamEvent" %}
      {% end %}

      ensure_open
      definition = Topology.stream_definition
      identity = Event.stream_event_identity
      envelope = EventEnvelope.new(
        message_id,
        identity.source,
        identity.event,
        identity.schema_version,
        Microservices.utc_now,
        correlation_id: correlation_id,
        causation_id: causation_id,
        headers: headers,
        payload: JSON.parse(event.to_json),
        limits: codec.limits,
      )
      message = ::Crabbit::Message.new(
        codec.encode_event(envelope),
        header: ::Crabbit::Header.new(durable: true),
        properties: ::Crabbit::Properties.new(
          message_id: message_id.to_s,
          subject: identity.routing_key,
          correlation_id: correlation_id.try(&.to_s),
          content_type: codec.profile.event_content_type,
          creation_time: envelope.occurred_at,
          group_id: routing_key,
        ),
      )

      if definition.super_stream?
        key = routing_key || raise StreamConfigurationError.new(
          "routing_key is required for super stream #{definition.name}",
        )
        handle = super_producer(definition).publish(message, key)
        track(handle.handles)
        StreamPublishReceipt.new(
          message_id,
          identity,
          definition.name,
          handle.handles,
        )
      else
        handle = producer(definition).publish(message, identity.routing_key)
        track([handle])
        StreamPublishReceipt.new(message_id, identity, definition.name, [handle])
      end
    rescue error : StreamError
      raise error
    rescue error : Exception
      raise StreamPublishError.new(message_id, error.message || error.class.to_s, error)
    end

    def drain(deadline : Time::Instant) : Bool
      @mutex.synchronize { @accepting = false }
      loop do
        return true if @mutex.synchronize { @pending.empty? }
        return false if Time.instant >= deadline
        sleep 1.millisecond
      end
    end

    def close : Nil
      producers, super_producers = @mutex.synchronize do
        return if @closed
        @accepting = false
        @closed = true
        ordinary = @producers.values
        supers = @super_producers.values
        @producers.clear
        @super_producers.clear
        {ordinary, supers}
      end
      first_error = nil.as(Exception?)
      super_producers.each do |producer|
        begin
          producer.close
        rescue error : Exception
          first_error ||= error
        end
      end
      producers.each do |producer|
        begin
          producer.close
        rescue error : Exception
          first_error ||= error
        end
      end
      raise first_error.as(Exception) if first_error
    end

    private def producer(definition : StreamTopologyDefinition) : ::Crabbit::Producer
      @mutex.synchronize do
        ensure_open_locked
        @producers[definition.name] ||= environment.producer(
          definition.name,
          effective_producer_options(definition.name),
        )
      end
    end

    private def super_producer(definition : StreamTopologyDefinition) : ::Crabbit::SuperStreamProducer
      @mutex.synchronize do
        ensure_open_locked
        @super_producers[definition.name] ||= environment.super_stream_producer(
          definition.name,
          ::Crabbit::SuperStreamProducerOptions.new(
            ->(message : ::Crabbit::Message) {
              message.properties.try(&.group_id) || raise StreamConfigurationError.new(
                "super stream message has no routing key",
              )
            },
            producer: effective_producer_options(definition.name),
          ),
        )
      end
    end

    private def effective_producer_options(topology : String) : ::Crabbit::ProducerOptions
      configured = @producer_options
      return configured if configured

      ::Crabbit::ProducerOptions.new(
        name: "#{producer_name}.#{topology}",
        filter_value_extractor: ->(message : ::Crabbit::Message) { message.properties.try(&.subject) },
      )
    end

    private def ensure_open : Nil
      @mutex.synchronize { ensure_open_locked }
    end

    private def ensure_open_locked : Nil
      raise StreamRuntimeError.new("Stream publisher is closed") if @closed
      raise StreamRuntimeError.new("Stream publisher is quiescing") unless @accepting
    end

    private def track(handles : Array(::Crabbit::PublishHandle)) : Nil
      @mutex.synchronize { @pending.concat(handles) }
      handles.each do |handle|
        handle.on_confirm do |_confirmation|
          @mutex.synchronize { @pending.delete(handle) }
        end
      end
    end
  end
end
