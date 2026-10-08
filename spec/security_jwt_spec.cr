require "./spec_helper"
require "jwt"
require "openssl"
require "../src/opal"
require "../src/opal/security/jwt"

private class SecurityJWTTestOIDCProvider
  getter issuer : String

  @server : HTTP::Server
  @address : Socket::IPAddress
  @jwks_uri : String
  @request_count = Atomic(Int32).new(0)

  def initialize(@jwks_uri_override : String? = nil, tls = false)
    @issuer = ""
    @jwks_uri = ""
    @server = HTTP::Server.new { |context| handle(context) }
    if tls
      tls_context = OpenSSL::SSL::Context::Server.new
      tls_context.certificate_chain = File.join(__DIR__, "fixtures", "security_jwt_cert.pem")
      tls_context.private_key = File.join(__DIR__, "fixtures", "security_jwt_private.pem")
      @address = @server.bind_tls("127.0.0.1", tls_context)
    else
      @address = @server.bind_tcp("127.0.0.1", 0)
    end
    scheme = tls ? "https" : "http"
    @issuer = "#{scheme}://127.0.0.1:#{@address.port}/realms/dev"
    @jwks_uri = @jwks_uri_override || "#{scheme}://127.0.0.1:#{@address.port}/realms/dev/keys"
    spawn { @server.listen }
    Fiber.yield
  end

  def request_count : Int32
    @request_count.get
  end

  def close : Nil
    @server.close
  end

  private def handle(context : HTTP::Server::Context) : Nil
    @request_count.add(1)
    case context.request.path
    when "/realms/dev/.well-known/openid-configuration"
      context.response.content_type = "application/json"
      context.response.print({"issuer" => @issuer, "jwks_uri" => @jwks_uri}.to_json)
    when "/realms/dev/keys"
      context.response.content_type = "application/json"
      context.response.print(security_jwt_test_jwks)
    else
      context.response.status = HTTP::Status::NOT_FOUND
    end
  end

  private def security_jwt_test_jwks : String
    {
      "keys" => [{
        "kty" => "RSA",
        "kid" => "opal-test-key",
        "use" => "sig",
        "alg" => "RS256",
        "e"   => "AQAB",
        "n"   => "4TGylSSgNd_iRNRwxYeF2_ONR23ozpZj6L3zZTXWP47bf6rxGYC9vmw6eIkpvmBPLNQ5C7oVTJJcNvngwYg_VnExPo3YL4PYi5yF2Ribk5jj1RgxVbOET7uOGmTwHde11h9TvP_XvLfoXbMFEXTj-SPD2irqn99X8oNhdxPC6CpO28J6s_IJSmRnPqHK9SJvyPdK2Qz7sig06tFcftQqqrpbLH_VZkiEZtcf_OKcFog_FuYWJCDTSqqKG5No1tBaYJ3vRgiF1yUCgz4ekPTxiF2DjpQexU7psDZljakKbb_rIj6nqfI8CDdemR7A_WtkryCiqelKZkOlrbDYmC2Exw",
      }],
    }.to_json
  end
end

private def security_jwt_test_token(
  issuer : String,
  audience = "opal-api",
  key = File.read(File.join(__DIR__, "fixtures", "security_jwt_private.pem")),
  expiration = Time.utc.to_unix + 60,
  not_before : Int64? = nil,
) : String
  payload = {
    "sub"   => "oidc-user",
    "scope" => "projects:read",
    "iss"   => issuer,
    "aud"   => audience,
    "exp"   => expiration,
  }
  if value = not_before
    payload["nbf"] = value
  end

  JWT.encode(
    payload,
    key,
    JWT::Algorithm::RS256,
    kid: "opal-test-key"
  )
end

describe "security JWT adapter" do
  it "rejects an HTTP OIDC issuer unless insecure HTTP is explicitly enabled" do
    expect_raises(LF::Security::ConfigurationError) do
      LF::Security::OIDCAuthenticator.new("http://keycloak:8080/realms/dev", "opal-api")
    end
  end

  it "allows an explicitly opted-in HTTP issuer with a Docker hostname" do
    authenticator = LF::Security::OIDCAuthenticator.new(
      "http://keycloak:8080/realms/dev",
      "opal-api",
      allow_insecure_http: true
    )

    authenticator.should be_a(LF::Security::OIDCAuthenticator)
  end

  it "validates OIDC tokens through HTTPS without the HTTP opt-in" do
    provider = SecurityJWTTestOIDCProvider.new(tls: true)
    previous_ssl_cert_file = ENV["SSL_CERT_FILE"]?
    ENV["SSL_CERT_FILE"] = File.join(__DIR__, "fixtures", "security_jwt_cert.pem")
    authenticator = LF::Security::OIDCAuthenticator.new(provider.issuer, "opal-api")
    token = security_jwt_test_token(provider.issuer)
    request = HTTP::Request.new("GET", "/", HTTP::Headers{"Authorization" => "Bearer #{token}"})

    authentication = authenticator.authenticate(request).not_nil!

    authentication.method.should eq(LF::Security::AuthenticationMethod::OIDC)
    authentication.principal.not_nil!.subject.should eq("oidc-user")
    provider.request_count.should eq(2)
  ensure
    provider.try(&.close)
    if previous_ssl_cert_file
      ENV["SSL_CERT_FILE"] = previous_ssl_cert_file
    else
      ENV.delete("SSL_CERT_FILE")
    end
  end

  it "validates OIDC tokens over HTTP and caches metadata and keys" do
    provider = SecurityJWTTestOIDCProvider.new
    authenticator = LF::Security::OIDCAuthenticator.new(
      provider.issuer,
      "opal-api",
      allow_insecure_http: true
    )
    request = HTTP::Request.new(
      "GET",
      "/",
      HTTP::Headers{"Authorization" => "Bearer #{security_jwt_test_token(provider.issuer)}"}
    )

    2.times do
      authentication = authenticator.authenticate(request).not_nil!
      authentication.principal.not_nil!.subject.should eq("oidc-user")
    end

    provider.request_count.should eq(2)
  ensure
    provider.try(&.close)
  end

  it "rejects a token with an unexpected issuer before discovery" do
    provider = SecurityJWTTestOIDCProvider.new
    authenticator = LF::Security::OIDCAuthenticator.new(
      provider.issuer,
      "opal-api",
      allow_insecure_http: true
    )
    token = security_jwt_test_token("http://attacker.invalid/realms/dev")
    request = HTTP::Request.new("GET", "/", HTTP::Headers{"Authorization" => "Bearer #{token}"})

    expect_raises(LF::Security::InvalidCredentials) { authenticator.authenticate(request) }
    provider.request_count.should eq(0)
  ensure
    provider.try(&.close)
  end

  it "continues to validate the audience for HTTP OIDC tokens" do
    provider = SecurityJWTTestOIDCProvider.new
    authenticator = LF::Security::OIDCAuthenticator.new(
      provider.issuer,
      "opal-api",
      allow_insecure_http: true
    )
    token = security_jwt_test_token(provider.issuer, "different-api")
    request = HTTP::Request.new("GET", "/", HTTP::Headers{"Authorization" => "Bearer #{token}"})

    expect_raises(LF::Security::InvalidCredentials) { authenticator.authenticate(request) }
  ensure
    provider.try(&.close)
  end

  it "rejects an invalid signature for HTTP OIDC tokens" do
    provider = SecurityJWTTestOIDCProvider.new
    authenticator = LF::Security::OIDCAuthenticator.new(
      provider.issuer,
      "opal-api",
      allow_insecure_http: true
    )
    parts = security_jwt_test_token(provider.issuer).split('.')
    signature = parts[2]
    parts[2] = (signature[0] == 'A' ? 'B' : 'A') + signature[1..]
    request = HTTP::Request.new("GET", "/", HTTP::Headers{"Authorization" => "Bearer #{parts.join(".")}"})

    expect_raises(LF::Security::InvalidCredentials) { authenticator.authenticate(request) }
  ensure
    provider.try(&.close)
  end

  it "rejects expired HTTP OIDC tokens" do
    provider = SecurityJWTTestOIDCProvider.new
    authenticator = LF::Security::OIDCAuthenticator.new(
      provider.issuer,
      "opal-api",
      allow_insecure_http: true
    )
    token = security_jwt_test_token(provider.issuer, expiration: Time.utc.to_unix - 120)
    request = HTTP::Request.new("GET", "/", HTTP::Headers{"Authorization" => "Bearer #{token}"})

    expect_raises(LF::Security::InvalidCredentials) { authenticator.authenticate(request) }
  ensure
    provider.try(&.close)
  end

  it "rejects HTTP OIDC tokens before their not-before time" do
    provider = SecurityJWTTestOIDCProvider.new
    authenticator = LF::Security::OIDCAuthenticator.new(
      provider.issuer,
      "opal-api",
      allow_insecure_http: true
    )
    token = security_jwt_test_token(provider.issuer, not_before: Time.utc.to_unix + 120)
    request = HTTP::Request.new("GET", "/", HTTP::Headers{"Authorization" => "Bearer #{token}"})

    expect_raises(LF::Security::InvalidCredentials) { authenticator.authenticate(request) }
  ensure
    provider.try(&.close)
  end

  it "rejects an HTTP JWKS URI outside the configured issuer origin" do
    provider = SecurityJWTTestOIDCProvider.new("http://attacker.invalid:8080/keys")
    authenticator = LF::Security::OIDCAuthenticator.new(
      provider.issuer,
      "opal-api",
      allow_insecure_http: true
    )
    token = security_jwt_test_token(provider.issuer)
    request = HTTP::Request.new("GET", "/", HTTP::Headers{"Authorization" => "Bearer #{token}"})

    expect_raises(LF::Security::InvalidCredentials) { authenticator.authenticate(request) }
    provider.request_count.should eq(1)
  ensure
    provider.try(&.close)
  end

  it "pins the verification algorithm and maps scope to authorities" do
    key = "jwt-test-key"
    token = JWT.encode(
      {
        "sub"   => "jwt-user",
        "scope" => "projects:read projects:write",
        "iss"   => "https://issuer.example.test",
        "aud"   => "opal-api",
        "exp"   => Time.utc.to_unix + 60,
      },
      key,
      JWT::Algorithm::HS256
    )
    authenticator = LF::Security::JWTAuthenticator.new(
      key,
      JWT::Algorithm::HS256,
      issuer: "https://issuer.example.test",
      audience: "opal-api"
    )
    request = HTTP::Request.new("GET", "/", HTTP::Headers{"Authorization" => "Bearer #{token}"})

    authentication = authenticator.authenticate(request).not_nil!

    authentication.method.should eq(LF::Security::AuthenticationMethod::BearerToken)
    authentication.principal.not_nil!.subject.should eq("jwt-user")
    authentication.principal.not_nil!.authorized_for?("projects:write").should be_true
  end

  it "rejects an unexpected issuer and an unsigned token" do
    key = "jwt-test-key"
    wrong_issuer = JWT.encode(
      {"sub" => "jwt-user", "iss" => "https://wrong.example.test", "exp" => Time.utc.to_unix + 60},
      key,
      JWT::Algorithm::HS256
    )
    unsigned = JWT.encode(
      {"sub" => "jwt-user", "iss" => "https://issuer.example.test", "exp" => Time.utc.to_unix + 60},
      "",
      JWT::Algorithm::None
    )
    authenticator = LF::Security::JWTAuthenticator.new(key, JWT::Algorithm::HS256, issuer: "https://issuer.example.test")

    wrong_request = HTTP::Request.new("GET", "/", HTTP::Headers{"Authorization" => "Bearer #{wrong_issuer}"})
    unsigned_request = HTTP::Request.new("GET", "/", HTTP::Headers{"Authorization" => "Bearer #{unsigned}"})

    expect_raises(LF::Security::InvalidCredentials) { authenticator.authenticate(wrong_request) }
    expect_raises(LF::Security::InvalidCredentials) { authenticator.authenticate(unsigned_request) }
  end
end
