require "./security/error"
require "./security/authentication"
require "./security/di_integration"
require "./security/api_key"
require "./security/signed_session"
require "./security/http"
require "./security/autoconfig"

# Optional authentication and authorization support.
#
# Load with `require "opal/security"` to compose API-key and signed-session
# authenticators with controller guards and CSRF protection. JWT and OIDC
# resource-token adapters are deliberately separate in `opal/security/jwt`.
module LF::Security
end
