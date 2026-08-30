require "http/status"

module LF::HTTP
  class Error < Exception
    getter status_code : ::HTTP::Status

    def initialize(message : String, @status_code : ::HTTP::Status)
      super(message)
    end
  end

  class NotFound < Error
    def initialize(message : String = "Not Found")
      super(message, ::HTTP::Status::NOT_FOUND)
    end
  end

  class BadRequest < Error
    def initialize(message : String = "Bad Request")
      super(message, ::HTTP::Status::BAD_REQUEST)
    end
  end

  class Forbidden < Error
    def initialize(message : String = "Forbidden")
      super(message, ::HTTP::Status::FORBIDDEN)
    end
  end

  class InternalServerError < Error
    def initialize(message : String = "Internal Server Error")
      super(message, ::HTTP::Status::INTERNAL_SERVER_ERROR)
    end
  end
end
