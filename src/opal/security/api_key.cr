require "http/request"
require "./authentication"

module LF::Security
  # Verifies API keys from a dedicated header or an Authorization scheme. The
  # supplied secret is compared against every configured key in fixed length
  # time; do not use a Hash lookup for a secret value.
  class APIKeyAuthenticator < Authenticator
    def initialize(
      @keys : Hash(String, Principal),
      @header = "Authorization",
      @scheme = "ApiKey",
    )
      raise ConfigurationError.new("At least one API key is required") if @keys.empty?
    end

    def authenticate(request : ::HTTP::Request) : Authentication?
      presented = credential(request)
      return nil unless presented

      @keys.each do |key, principal|
        if Security.secure_compare(key, presented)
          return Authentication.new(principal, AuthenticationMethod::APIKey)
        end
      end
      raise InvalidCredentials.new("Invalid API key")
    end

    private def credential(request : ::HTTP::Request) : String?
      value = request.headers[@header]?
      return nil unless value

      prefix = "#{@scheme} "
      return nil unless value.starts_with?(prefix)

      key = value[prefix.bytesize..]
      raise InvalidCredentials.new("Missing API key") if key.empty?
      key
    end
  end
end
