# Security

Security is opt-in and composes existing HTTP guards and interceptors. It does
not introduce a second authorization pipeline, runtime reflection, or an
expression language.

## Enable authentication

Require the normal HTTP autoconfiguration and security package, register one
explicit `security_authenticator` bean, then enable the Security extension on
the application:

```crystal
require "opal"
require "opal/autoconfig/http"
require "opal/security"

@[LF::ApplicationConfiguration]
class SecurityConfiguration
  @[LF::DI::Bean(name: "security_authenticator")]
  def authenticator : LF::Security::Authenticator
    LF::Security::APIKeyAuthenticator.new({
      ENV["API_KEY"] => LF::Security::Principal.new(
        "service-client",
        ["projects:read"]
      ),
    })
  end
end

@[LF::Application]
@[LF::AutoConfig::Security]
@[LF::AutoConfig::HTTP]
class API
end
```

`AuthenticationHandler` runs after Opal creates the request scope and before
the controller router. Its immutable result stays on the HTTP context through a
WebSocket upgrade, so the same guards protect controller actions, WebSocket
handshakes, and LiveView mounts/reconnects. If no authenticator bean exists,
requests are anonymous; routes remain public until an application adds guards.

## Authorization

Use the existing `UseGuards` annotation at application, controller, action, or
LiveView scope:

```crystal
@[LF::HTTP::UseGuards(LF::Security::AuthenticatedGuard)]
class ProjectsController
  include LF::HTTP::Controller

  @[LF::HTTP::Controller::Get("/projects")]
  def index : String
    "projects"
  end
end
```

For permissions, implement one small named guard. It runs through the same
ordered, request-scoped mechanism as all other guards:

```crystal
@[LF::DI::Service]
class ProjectReadGuard < LF::Security::AuthorityGuard
  def required_authorities : Enumerable(String)
    ["projects:read"]
  end
end

@[LF::HTTP::UseGuards(ProjectReadGuard)]
class ProjectsController
  include LF::HTTP::Controller
end
```

An anonymous caller receives `401 Unauthorized`; an authenticated caller that
lacks an authority receives `403 Forbidden`. Keep resource ownership checks in
ordinary application services after loading the typed resource—there is no
SpEL-style string expression language.

## API keys

`APIKeyAuthenticator` accepts `Authorization: ApiKey <secret>`, compares
configured secrets without an early exit, and maps each key to a principal:

```crystal
LF::Security::APIKeyAuthenticator.new({
  ENV["DEPLOY_KEY"] => LF::Security::Principal.new("deploy", ["deploy:write"]),
})
```

Combine mechanisms explicitly when an API accepts more than one credential:

```crystal
LF::Security::AuthenticatorChain.new([
  api_key_authenticator,
  signed_session,
])
```

## Browser sessions and CSRF

`SignedSession` creates an HMAC-SHA256 signed, HttpOnly, Secure,
`SameSite=Lax` `__Host-` cookie. Its payload is not encrypted: do not put
sensitive claims in it. Issue a session after application login and add the
cookie to the response:

```crystal
issued = signed_session.issue(principal)
context.response.cookies << issued.cookie
# Deliver issued.csrf_token only to the same rendered browser document.
```

Protect state-changing browser actions with the existing interceptor mechanism:

```crystal
@[LF::HTTP::UseInterceptors(LF::Security::CSRFInterceptor)]
class BrowserController
  include LF::HTTP::Controller
end
```

The interceptor validates `X-CSRF-Token` only for unsafe requests authenticated
by `SignedSession`. Bearer-token and API-key APIs are not subject to CSRF.

## JWT and OIDC

JWT/OIDC stays an opt-in adapter to avoid a mandatory dependency. Add the
maintained JWT shard to the application and require the adapter:

```yaml
dependencies:
  jwt:
    github: crystal-community/jwt
```

```crystal
require "opal/security/jwt"

jwt = LF::Security::JWTAuthenticator.new(
  ENV["JWT_PUBLIC_KEY"],
  JWT::Algorithm::RS256,
  issuer: "https://issuer.example.test",
  audience: "opal-api",
)

oidc = LF::Security::OIDCAuthenticator.new(
  "https://issuer.example.test",
  "opal-api",
)
```

`JWTAuthenticator` pins its configured algorithm and validates signature,
expiry, not-before, issuer, and audience. `OIDCAuthenticator` delegates OIDC
discovery and HTTPS JWKS caching to the JWT shard; its validated `scope` claim
becomes the Opal authority set by default.
