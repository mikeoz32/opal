module LF::Microservices
  class StreamError < Error
  end

  class StreamConfigurationError < StreamError
  end

  class StreamTopologyError < StreamError
  end

  class StreamPublishError < StreamError
    getter message_id : UUID

    def initialize(@message_id : UUID, reason : String, cause : Exception? = nil)
      super("Stream publication #{message_id} failed: #{reason}", cause)
    end
  end

  class StreamHandlerError < StreamError
  end

  class StreamRuntimeError < StreamError
  end

  class StreamDrainTimeoutError < StreamRuntimeError
    include LF::ApplicationExtension::StopIncomplete

    def initialize
      super("Stream handlers did not drain before the shutdown deadline")
    end
  end
end
