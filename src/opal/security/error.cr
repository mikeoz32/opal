module LF::Security
  class Error < Exception
  end

  # Credentials were presented for this authentication mechanism but could not
  # be verified. Absence of credentials is represented by a nil result instead.
  class InvalidCredentials < Error
    def initialize(message : String = "Invalid credentials")
      super(message)
    end
  end

  class ConfigurationError < Error
  end
end
