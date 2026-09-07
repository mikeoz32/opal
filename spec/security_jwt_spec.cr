require "./spec_helper"
require "jwt"
require "../src/opal"
require "../src/opal/security/jwt"

describe "security JWT adapter" do
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
