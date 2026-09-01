module LF::LiveView
  class Error < Exception
  end

  class ConfigurationError < Error
  end

  class UnknownEventError < Error
    getter event : String

    def initialize(@event)
      super("Unknown LiveView event: #{event}")
    end
  end

  class UnknownInfoError < Error
    getter info : String

    def initialize(@info)
      super("Unknown LiveView info: #{info}")
    end
  end

  class UnknownComponentError < Error
    def initialize
      super("Unknown LiveView component target")
    end
  end

  class DuplicateComponentError < Error
    def initialize(type : String)
      super("Duplicate LiveView component identity for #{type}")
    end
  end

  class RecursiveComponentError < Error
    def initialize(type : String, id : String)
      super("Recursive LiveView component identity for #{type}: #{id}")
    end
  end

  class ComponentNestingError < Error
    def initialize(max_depth : Int32)
      super("LiveView components cannot be nested deeper than #{max_depth} levels")
    end
  end

  class DuplicateNavigationError < Error
    def initialize
      super("A LiveView callback can request only one navigation")
    end
  end

  class EventReplyError < Error
  end

  class InvalidNavigationError < Error
    def initialize
      super("Invalid LiveView navigation")
    end
  end

  class InvalidMountTokenError < Error
    def initialize
      super("Invalid LiveView mount token")
    end
  end

  class ProtocolError < Error
  end
end
