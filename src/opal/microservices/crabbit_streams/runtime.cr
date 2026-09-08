module LF::Microservices
  enum StreamRuntimeStatus
    Created
    Running
    Degraded
    Quiescing
    Closed
  end

  record StreamPartitionFailure,
    topology : String,
    subscription : String,
    stream : String,
    offset : UInt64,
    identity : EventIdentity?,
    error : Exception,
    attempts : Int32,
    failed_at : Time

  class StreamRuntimeSettings
    getter create_topology : Bool
    getter initial_offset : ::Crabbit::OffsetSpecification
    getter initial_credit : UInt16
    getter buffer_size : Int32
    getter concurrency : Int32
    getter retry_policy : StreamRetryPolicy
    getter topology_refresh : Time::Span
    getter single_active_consumer : Bool

    def initialize(
      @create_topology : Bool = false,
      @initial_offset : ::Crabbit::OffsetSpecification = ::Crabbit::OffsetSpecification.first,
      @initial_credit : UInt16 = 10_u16,
      buffer_size : Int = 1_024,
      concurrency : Int = 1,
      @retry_policy : StreamRetryPolicy = StreamRetryPolicy.new,
      @topology_refresh : Time::Span = 30.seconds,
      @single_active_consumer : Bool = true,
    )
      raise StreamConfigurationError.new("initial_credit must be positive") unless initial_credit > 0
      unless buffer_size > 0 && buffer_size <= Int32::MAX
        raise StreamConfigurationError.new("buffer_size must be a positive 32-bit integer")
      end
      unless concurrency > 0 && concurrency <= Int32::MAX
        raise StreamConfigurationError.new("concurrency must be a positive 32-bit integer")
      end
      raise StreamConfigurationError.new("topology_refresh must be positive") unless topology_refresh > 0.seconds
      @buffer_size = buffer_size.to_i32
      @concurrency = concurrency.to_i32
    end
  end

  # Owns Crabbit pull consumers, typed dispatch, broker checkpoints, retries,
  # super-stream partition reconciliation, and application lifecycle.
  class StreamHandlerRuntime
    getter environment : ::Crabbit::Environment
    getter registry : StreamHandlerRegistry
    getter codec : JSONCodec
    getter settings : StreamRuntimeSettings

    @mutex = Mutex.new
    @status = StreamRuntimeStatus::Created
    @context : LF::ApplicationContext?
    @consumers = {} of String => ::Crabbit::Consumer
    @failures = {} of String => StreamPartitionFailure
    @worker_count = 0
    @refresh_stop = Channel(Nil).new
    @refresh_finished = Channel(Nil).new
    @refresh_started = false

    def initialize(
      @environment : ::Crabbit::Environment,
      @registry : StreamHandlerRegistry,
      @settings : StreamRuntimeSettings = StreamRuntimeSettings.new,
      @codec : JSONCodec = JSONCodec.new,
      topologies : Enumerable(StreamTopologyDefinition) = [] of StreamTopologyDefinition,
    )
      raise StreamConfigurationError.new("stream handler registry must be sealed") unless registry.sealed?
      @declared_topologies = topologies.to_a
    end

    def status : StreamRuntimeStatus
      @mutex.synchronize { @status }
    end

    def ready? : Bool
      status.running?
    end

    def failures : Array(StreamPartitionFailure)
      @mutex.synchronize { @failures.values }
    end

    def configure(context : LF::ApplicationContext) : Nil
      @mutex.synchronize do
        raise StreamRuntimeError.new("Stream runtime is already configured") unless @status.created?
        @context = context
      end

      definitions.each { |definition| prepare_topology(definition) }
      registry.subscriptions.each { |plan| start_subscription(plan) }
      start_topology_refresh
      @mutex.synchronize { @status = @failures.empty? ? StreamRuntimeStatus::Running : StreamRuntimeStatus::Degraded }
    rescue error : Exception
      begin
        close
      rescue
      end
      raise error
    end

    def quiesce(context : LF::ShutdownContext) : Nil
      consumers = @mutex.synchronize do
        return if @status.closed?
        @status = StreamRuntimeStatus::Quiescing
        @consumers.values
      end
      stop_refresh
      consumers.each(&.close)
      until workers_drained?
        raise StreamDrainTimeoutError.new if context.expired?
        sleep 1.millisecond
      end
    end

    def close : Nil
      consumers = @mutex.synchronize do
        return if @status.closed?
        @status = StreamRuntimeStatus::Quiescing
        values = @consumers.values
        @consumers.clear
        values
      end
      stop_refresh
      consumers.each do |consumer|
        begin
          consumer.close
        rescue
        end
      end
      @mutex.synchronize { @status = StreamRuntimeStatus::Closed }
    end

    # Restarts one previously failed physical stream/partition from its broker
    # checkpoint. Returns false when no matching failed subscription exists.
    def resume(topology : String, subscription : String, stream : String) : Bool
      plan = registry.subscriptions.find do |candidate|
        candidate.topology.name == topology && candidate.subscription == subscription
      end
      return false unless plan
      key = consumer_key(plan, stream)
      previous = @mutex.synchronize do
        return false unless @failures.delete(key)
        @consumers.delete(key)
      end
      previous.try(&.close)
      start_consumer(plan, stream)
      @mutex.synchronize { @status = @failures.empty? ? StreamRuntimeStatus::Running : StreamRuntimeStatus::Degraded }
      true
    end

    private def definitions : Array(StreamTopologyDefinition)
      (@declared_topologies + registry.subscriptions.map(&.topology)).uniq
    end

    private def prepare_topology(definition : StreamTopologyDefinition) : Nil
      if definition.super_stream?
        partitions = super_stream_partitions(definition)
        if partitions.empty?
          unless settings.create_topology
            raise StreamTopologyError.new("super stream #{definition.name} does not exist")
          end
          create_super_stream(definition)
          partitions = environment.partitions(definition.name)
        end
        unless compatible_partitions?(definition, partitions)
          raise StreamTopologyError.new(
            "super stream #{definition.name} partitions are incompatible: required #{definition.partition_names}, got #{partitions}",
          )
        end
      elsif !environment.stream_exists?(definition.name)
        unless settings.create_topology
          raise StreamTopologyError.new("stream #{definition.name} does not exist")
        end
        create_stream(definition)
      end
    rescue error : StreamError
      raise error
    rescue error : Exception
      raise StreamTopologyError.new(
        "could not prepare topology #{definition.name}: #{error.message || error.class}",
        error,
      )
    end

    # Another replica may declare the same topology after the existence check.
    # Treat that broker race as success only after reading the topology back.
    private def create_stream(definition : StreamTopologyDefinition) : Nil
      environment.create_stream(definition.name, definition.options)
    rescue error : Exception
      raise error unless environment.stream_exists?(definition.name)
    end

    private def create_super_stream(definition : StreamTopologyDefinition) : Nil
      environment.create_super_stream(
        definition.name,
        definition.partition_names,
        definition.binding_keys,
        definition.options.arguments,
      )
    rescue error : Exception
      partitions = super_stream_partitions(definition)
      raise error unless compatible_partitions?(definition, partitions)
    end

    private def super_stream_partitions(definition : StreamTopologyDefinition) : Array(String)
      environment.partitions(definition.name)
    rescue error : ::Crabbit::BrokerError
      [] of String
    end

    private def start_subscription(plan : StreamSubscriptionPlan) : Nil
      streams = plan.topology.super_stream? ? environment.partitions(plan.topology.name) : [plan.topology.name]
      streams.each { |stream| start_consumer(plan, stream) }
    end

    private def start_consumer(plan : StreamSubscriptionPlan, stream : String) : Nil
      key = consumer_key(plan, stream)
      return if @mutex.synchronize { @consumers.has_key?(key) || @failures.has_key?(key) || @status.quiescing? || @status.closed? }

      stored = environment.query_offset(plan.subscription, stream)
      if stored == UInt64::MAX
        raise StreamRuntimeError.new("stored offset for #{plan.subscription} on #{stream} cannot be incremented")
      end
      offset = stored ? ::Crabbit::OffsetSpecification.offset(stored + 1_u64) : settings.initial_offset
      consumer = environment.consumer(
        stream,
        ::Crabbit::ConsumerOptions.new(
          name: plan.subscription,
          offset: offset,
          initial_credit: settings.initial_credit,
          single_active_consumer: settings.single_active_consumer,
          super_stream: plan.topology.super_stream? ? plan.topology.name : nil,
          buffer_size: settings.buffer_size,
          auto_store_every: 1,
        ),
      )
      accepted = @mutex.synchronize do
        if @status.quiescing? || @status.closed?
          false
        else
          @consumers[key] = consumer
          true
        end
      end
      unless accepted
        consumer.close
        return
      end

      settings.concurrency.times do
        @mutex.synchronize { @worker_count += 1 }
        spawn(name: "opal-stream-#{plan.subscription}-#{stream}") do
          begin
            consume(plan, key, consumer)
          ensure
            @mutex.synchronize { @worker_count -= 1 }
          end
        end
      end
    rescue error : Exception
      raise StreamRuntimeError.new(
        "could not start #{plan.subscription} on #{stream}: #{error.message || error.class}",
        error,
      )
    end

    private def consume(
      plan : StreamSubscriptionPlan,
      key : String,
      consumer : ::Crabbit::Consumer,
    ) : Nil
      while delivery = consumer.receive?
        break if failed?(key)
        if failure = process_with_retry(plan, delivery)
          poison(key, plan, consumer, delivery, failure)
          break
        end
        delivery.processed!
      end
    rescue error : ::Crabbit::ResourceClosedError | Channel::ClosedError
    rescue error : Exception
      unless stopping?
        synthetic = StreamPartitionFailure.new(
          plan.topology.name,
          plan.subscription,
          consumer.stream,
          0_u64,
          nil,
          error,
          1,
          Microservices.utc_now,
        )
        poison(key, consumer, synthetic)
      end
    end

    private def process_with_retry(
      plan : StreamSubscriptionPlan,
      delivery : ::Crabbit::Delivery,
    ) : Tuple(Exception, Int32, EventIdentity?)?
      identity = nil.as(EventIdentity?)
      settings.retry_policy.max_attempts.times do |index|
        begin
          envelope, decoded_identity = decode_delivery(delivery)
          identity = decoded_identity
          process(plan, delivery, envelope, decoded_identity)
          return nil
        rescue error : Exception
          attempt = index + 1
          return {error, attempt, identity} if attempt >= settings.retry_policy.max_attempts
          sleep settings.retry_policy.delay(attempt)
        end
      end
      nil
    end

    private def process(
      plan : StreamSubscriptionPlan,
      delivery : ::Crabbit::Delivery,
      envelope : EventEnvelope,
      identity : EventIdentity,
    ) : Nil
      handler = plan.handler(identity)
      unless handler
        if plan.knows_event?(identity)
          raise StreamHandlerError.new(
            "unsupported schema version #{identity.schema_version} for #{identity.source.label}.#{identity.event}",
          )
        end
        return
      end

      scope = nil.as(LF::DI::Container?)
      body_error = nil.as(Exception?)
      begin
        scope = application_context.enter_scope("message")
        encoded = EncodedDelivery.new(
          envelope.message_id,
          identity.routing_key,
          delivery.message.body,
          Microservices.utc_now,
          correlation_id: envelope.correlation_id,
          content_type: codec.profile.event_content_type,
          limits: codec.limits,
        )
        execution_context = ExecutionContext.new(
          encoded,
          scope,
          handler.handler,
          handler.action,
          event_identity: identity,
          headers: envelope.headers,
          correlation_id: envelope.correlation_id,
          causation_id: envelope.causation_id,
          stream_metadata: StreamDeliveryMetadata.new(
            plan.topology.name,
            delivery.stream,
            plan.subscription,
            delivery.offset,
            delivery.timestamp,
            super_stream: plan.topology.super_stream? ? plan.topology.name : nil,
          ),
        )
        handler.invoke(scope, execution_context, envelope.payload)
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
      raise body_error.as(Exception) if body_error
    end

    private def decode_delivery(delivery : ::Crabbit::Delivery) : Tuple(EventEnvelope, EventIdentity)
      message = delivery.message
      unless message.body_kind.data?
        raise StreamHandlerError.new("stream delivery body must use an AMQP Data section")
      end
      if content_type = message.properties.try(&.content_type)
        unless content_type == codec.profile.event_content_type
          raise StreamHandlerError.new("unsupported stream event content_type: #{content_type}")
        end
      end
      envelope = codec.decode_event(message.body)
      identity = EventIdentity.new(envelope.source, envelope.event, envelope.schema_version)
      {envelope, identity}
    end

    private def poison(
      key : String,
      plan : StreamSubscriptionPlan,
      consumer : ::Crabbit::Consumer,
      delivery : ::Crabbit::Delivery,
      details : Tuple(Exception, Int32, EventIdentity?),
    ) : Nil
      error, attempts, identity = details
      failure = StreamPartitionFailure.new(
        plan.topology.name,
        plan.subscription,
        delivery.stream,
        delivery.offset,
        identity,
        error,
        attempts,
        Microservices.utc_now,
      )
      poison(key, consumer, failure)
    end

    private def poison(
      key : String,
      consumer : ::Crabbit::Consumer,
      failure : StreamPartitionFailure,
    ) : Nil
      @mutex.synchronize do
        @failures[key] = failure
        @status = StreamRuntimeStatus::Degraded unless @status.quiescing? || @status.closed?
      end
      consumer.close
    end

    private def start_topology_refresh : Nil
      return unless registry.subscriptions.any?(&.topology.super_stream?)
      @refresh_started = true
      spawn(name: "opal-stream-topology-refresh") do
        begin
          loop do
            select
            when @refresh_stop.receive?
              break
            when timeout(settings.topology_refresh)
              refresh_super_streams
            end
          end
        ensure
          @refresh_finished.close
        end
      end
    end

    private def refresh_super_streams : Nil
      registry.subscriptions.each do |plan|
        next unless plan.topology.super_stream?
        partitions = environment.partitions(plan.topology.name)
        expected = plan.topology.partition_names
        unless compatible_partitions?(plan.topology, partitions)
          raise StreamTopologyError.new(
            "super stream #{plan.topology.name} partitions are incompatible: required #{expected}, got #{partitions}",
          )
        end
        partitions.each { |stream| start_consumer(plan, stream) }
      end
      @mutex.synchronize do
        unless @status.quiescing? || @status.closed?
          @status = @failures.empty? ? StreamRuntimeStatus::Running : StreamRuntimeStatus::Degraded
        end
      end
    rescue error : Exception
      @mutex.synchronize do
        @status = StreamRuntimeStatus::Degraded unless @status.quiescing? || @status.closed?
      end
    end

    private def stop_refresh : Nil
      return unless @refresh_started
      begin
        @refresh_stop.close
      rescue
      end
      @refresh_finished.receive?
      @refresh_started = false
    end

    private def application_context : LF::ApplicationContext
      @context || raise StreamRuntimeError.new("Stream runtime is not configured")
    end

    private def compatible_partitions?(
      definition : StreamTopologyDefinition,
      partitions : Array(String),
    ) : Bool
      required = definition.partition_names
      prefix = "#{definition.name}-"
      required.all? { |partition| partitions.includes?(partition) } &&
        partitions.uniq.size == partitions.size &&
        partitions.all? { |partition| partition.starts_with?(prefix) }
    end

    private def consumer_key(plan : StreamSubscriptionPlan, stream : String) : String
      "#{plan.topology_type}:#{plan.subscription}:#{stream}"
    end

    private def failed?(key : String) : Bool
      @mutex.synchronize { @failures.has_key?(key) }
    end

    private def stopping? : Bool
      @mutex.synchronize { @status.quiescing? || @status.closed? }
    end

    private def workers_drained? : Bool
      @mutex.synchronize { @worker_count == 0 }
    end
  end
end
