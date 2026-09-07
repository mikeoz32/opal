require "../di"
require "./authentication"

class LF::DI::Container
  # Populated only by Security::AuthenticationHandler after authentication.
  # This stays optional on the base container so `require "opal"` does not
  # acquire a security dependency.
  property security_context : LF::Security::Context?
end
