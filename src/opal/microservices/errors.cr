module LF::Microservices
  class Error < Exception
  end

  class IdentityError < Error
  end

  class TopologyError < Error
  end

  class WireError < Error
  end

  class WireEncodingError < WireError
  end

  class WireDecodingError < WireError
  end

  class WireLimitError < WireError
  end

  class WireDeadlineError < WireError
  end

  class HandlerCompilationError < Error
  end

  class MessageInvocationError < Error
  end

  class MessageAuthorizationError < MessageInvocationError
  end

  class MessageConfigurationError < MessageInvocationError
  end

  class MessageRetryableError < MessageInvocationError
  end

  class MessageRejectedError < MessageInvocationError
  end

  class MessageScopeError < MessageInvocationError
    getter body_error : Exception?
    getter scope_error : Exception

    def initialize(@scope_error : Exception, @body_error : Exception? = nil)
      message = "message scope cleanup failed: #{scope_error.message || scope_error.class}"
      if body_error
        message += "; handler also failed: #{body_error.message || body_error.class}"
      end
      super(message, scope_error)
    end
  end

  class TransportError < Error
  end

  class TransportStateError < TransportError
  end

  class TransportUnavailableError < TransportError
  end

  class TransportTimeoutError < TransportError
  end

  class TransportIndeterminateError < TransportError
  end

  class TransportRejectedError < TransportError
  end

  class TransportUnroutableError < TransportError
  end

  class TransportCorrelationError < TransportError
  end

  class TransportCapacityError < TransportError
  end

  class DuplicateSettlementError < TransportError
  end
end
