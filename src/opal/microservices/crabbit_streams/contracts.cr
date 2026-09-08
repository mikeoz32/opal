module LF::Microservices
  # Declares the stable wire identity carried by a replayable stream event.
  annotation StreamEventContract
  end

  # Marks a JSON DTO as a typed stream event. The accompanying
  # `StreamEventContract` annotation is compiled into immutable identity
  # metadata used by publishers and handlers.
  module StreamEvent
    macro included
      macro finished
        \{% annotations = @type.annotations(LF::Microservices::StreamEventContract) %}
        \{% if annotations.size != 1 %}
          \{% raise "#{@type} must declare exactly one @[LF::Microservices::StreamEventContract] annotation" %}
        \{% end %}
        \{% descriptor = annotations.first %}
        \{% namespace = descriptor[:namespace] %}
        \{% service = descriptor[:service] %}
        \{% contract_version = descriptor[:contract_version] %}
        \{% event = descriptor[:event] %}
        \{% schema_version = descriptor[:schema_version] %}
        \{% unless namespace.is_a?(StringLiteral) && service.is_a?(StringLiteral) && event.is_a?(StringLiteral) %}
          \{% raise "Stream event identity on #{@type} must use string literals" %}
        \{% end %}
        \{% unless contract_version.is_a?(NumberLiteral) && schema_version.is_a?(NumberLiteral) %}
          \{% raise "Stream event versions on #{@type} must use integer literals" %}
        \{% end %}
        \{% unless @type.ancestors.includes?(JSON::Serializable) %}
          \{% raise "Stream event #{@type} must include JSON::Serializable" %}
        \{% end %}

        def self.stream_event_identity : LF::Microservices::EventIdentity
          LF::Microservices::EventIdentity.new(
            LF::Microservices::ServiceIdentity.new(
              \{{ namespace }},
              \{{ service }},
              \{{ contract_version }},
            ),
            \{{ event }},
            \{{ schema_version }},
          )
        end
      end
    end
  end

  enum StreamTopologyKind
    Stream
    SuperStream
  end

  # Immutable application-owned RabbitMQ Streams topology.
  struct StreamTopologyDefinition
    getter name : String
    getter kind : StreamTopologyKind
    getter partition_count : Int32
    getter options : ::Crabbit::StreamOptions

    def initialize(
      @name : String,
      @kind : StreamTopologyKind,
      partition_count : Int = 1,
      @options : ::Crabbit::StreamOptions = ::Crabbit::StreamOptions.new,
    )
      raise StreamConfigurationError.new("topology name must not be empty") if name.empty?
      unless partition_count > 0 && partition_count <= Int32::MAX
        raise StreamConfigurationError.new("partition_count must be a positive 32-bit integer")
      end
      @partition_count = partition_count.to_i32
      if kind.stream? && partition_count != 1
        raise StreamConfigurationError.new("an ordinary stream must have exactly one partition")
      end
    end

    def super_stream? : Bool
      kind.super_stream?
    end

    def partition_names : Array(String)
      return [name] unless super_stream?
      Array.new(partition_count) { |index| "#{name}-#{index}" }
    end

    def binding_keys : Array(String)
      Array.new(partition_count, &.to_s)
    end
  end

  # DSL mixed into a topology class referenced by publisher and handler
  # annotations.
  module StreamTopology
    macro stream(name, options = ::Crabbit::StreamOptions.new)
      def self.stream_definition : LF::Microservices::StreamTopologyDefinition
        LF::Microservices::StreamTopologyDefinition.new(
          {{ name }},
          LF::Microservices::StreamTopologyKind::Stream,
          options: {{ options }},
        )
      end
    end

    macro super_stream(name, partitions, options = ::Crabbit::StreamOptions.new)
      def self.stream_definition : LF::Microservices::StreamTopologyDefinition
        LF::Microservices::StreamTopologyDefinition.new(
          {{ name }},
          LF::Microservices::StreamTopologyKind::SuperStream,
          partition_count: {{ partitions }},
          options: {{ options }},
        )
      end
    end
  end

  struct StreamRetryPolicy
    getter max_attempts : Int32
    getter initial_delay : Time::Span
    getter max_delay : Time::Span

    def initialize(
      max_attempts : Int = 5,
      @initial_delay : Time::Span = 250.milliseconds,
      @max_delay : Time::Span = 10.seconds,
    )
      unless max_attempts > 0 && max_attempts <= Int32::MAX
        raise StreamConfigurationError.new("max_attempts must be a positive 32-bit integer")
      end
      raise StreamConfigurationError.new("initial_delay must not be negative") if initial_delay < 0.seconds
      raise StreamConfigurationError.new("max_delay must be positive") unless max_delay > 0.seconds
      raise StreamConfigurationError.new("max_delay must not precede initial_delay") if max_delay < initial_delay
      @max_attempts = max_attempts.to_i32
    end

    def delay(attempt : Int) : Time::Span
      multiplier = 1_i64 << Math.min(Math.max(attempt - 1, 0), 30)
      milliseconds = initial_delay.total_milliseconds * multiplier
      Math.min(milliseconds, max_delay.total_milliseconds).milliseconds
    end
  end

  # Declares one handler class for one typed stream event and subscription.
  annotation StreamHandler
  end

  # Marker required on classes compiled as stream handlers.
  module StreamProjection
  end

  alias StreamContext = ExecutionContext
end
