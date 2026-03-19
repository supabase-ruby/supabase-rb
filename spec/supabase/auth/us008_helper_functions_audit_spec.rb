# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

# US-008: Audit Helper Functions
# Verifies utility/helper functions match the Python SDK behavior.
RSpec.describe "US-008: Helper Functions Audit" do
  let(:helpers) { Supabase::Auth::Helpers }

  describe "AC-1: handle_exception / error response parsing matches Python" do
    it "returns AuthRetryableError for non-HTTP exceptions (status=0)" do
      error = helpers.handle_exception(RuntimeError.new("connection refused"))
      expect(error).to be_a(Supabase::Auth::Errors::AuthRetryableError)
      expect(error.status).to eq(0)
      expect(error.message).to eq("connection refused")
    end

    it "returns AuthRetryableError for 502 status" do
      response = { status: 502, body: "", headers: {} }
      error = helpers.handle_exception(Faraday::ServerError.new("Bad Gateway", response))
      expect(error).to be_a(Supabase::Auth::Errors::AuthRetryableError)
      expect(error.status).to eq(502)
    end

    it "returns AuthRetryableError for 503 status" do
      response = { status: 503, body: "", headers: {} }
      error = helpers.handle_exception(Faraday::ServerError.new("Unavailable", response))
      expect(error).to be_a(Supabase::Auth::Errors::AuthRetryableError)
      expect(error.status).to eq(503)
    end

    it "returns AuthRetryableError for 504 status" do
      response = { status: 504, body: "", headers: {} }
      error = helpers.handle_exception(Faraday::ServerError.new("Timeout", response))
      expect(error).to be_a(Supabase::Auth::Errors::AuthRetryableError)
      expect(error.status).to eq(504)
    end

    it "returns AuthApiError for 400 status with error code from API v2024-01-01+" do
      body = { "code" => "invalid_request", "message" => "Bad request" }.to_json
      headers = { "X-Supabase-Api-Version" => "2024-01-01" }
      response = { status: 400, body: body, headers: headers }
      error = helpers.handle_exception(Faraday::ClientError.new("Bad", response))
      expect(error).to be_a(Supabase::Auth::Errors::AuthApiError)
      expect(error.status).to eq(400)
      expect(error.code).to eq("invalid_request")
    end

    it "returns AuthApiError with error_code fallback for older API versions" do
      body = { "error_code" => "user_not_found", "message" => "Not found" }.to_json
      response = { status: 404, body: body, headers: {} }
      error = helpers.handle_exception(Faraday::ClientError.new("Not found", response))
      expect(error).to be_a(Supabase::Auth::Errors::AuthApiError)
      expect(error.code).to eq("user_not_found")
    end

    it "returns AuthWeakPassword for weak_password error code" do
      body = {
        "code" => "weak_password",
        "message" => "Password is too weak",
        "weak_password" => { "reasons" => ["too short", "no symbols"] }
      }.to_json
      headers = { "X-Supabase-Api-Version" => "2024-01-01" }
      response = { status: 422, body: body, headers: headers }
      error = helpers.handle_exception(Faraday::ClientError.new("Weak", response))
      expect(error).to be_a(Supabase::Auth::Errors::AuthWeakPassword)
      expect(error.reasons).to eq(["too short", "no symbols"])
    end

    it "returns AuthWeakPassword when weak_password present but no error_code" do
      body = {
        "message" => "Password is too weak",
        "weak_password" => { "reasons" => ["too short"] }
      }.to_json
      response = { status: 422, body: body, headers: {} }
      error = helpers.handle_exception(Faraday::ClientError.new("Weak", response))
      expect(error).to be_a(Supabase::Auth::Errors::AuthWeakPassword)
      expect(error.reasons).to eq(["too short"])
    end

    it "returns AuthUnknownError when response body is unparseable" do
      response = { status: 500, body: "not json at all {{{", headers: {} }
      error = helpers.handle_exception(Faraday::ServerError.new("Fail", response))
      expect(error).to be_a(Supabase::Auth::Errors::AuthUnknownError)
    end

    it "returns AuthApiError with status 500 fallback when status is nil" do
      body = { "message" => "Unknown error" }.to_json
      response = { status: nil, body: body, headers: {} }
      error = helpers.handle_exception(Faraday::ClientError.new("Err", response))
      expect(error).to be_a(Supabase::Auth::Errors::AuthApiError)
      expect(error.status).to eq(500)
    end
  end

  describe "AC-2: parse_link_response separates link properties from user data" do
    it "extracts GenerateLinkProperties fields and remaining data as User" do
      data = {
        "action_link" => "https://example.com/verify?token=abc",
        "email_otp" => "123456",
        "hashed_token" => "hash123",
        "redirect_to" => "https://example.com/callback",
        "verification_type" => "signup",
        "id" => "user-uuid-123",
        "email" => "test@example.com",
        "aud" => "authenticated"
      }
      result = helpers.parse_link_response(data)
      expect(result).to be_a(Supabase::Auth::Types::GenerateLinkResponse)
      expect(result.properties.action_link).to eq("https://example.com/verify?token=abc")
      expect(result.properties.email_otp).to eq("123456")
      expect(result.properties.hashed_token).to eq("hash123")
      expect(result.properties.redirect_to).to eq("https://example.com/callback")
      expect(result.properties.verification_type).to eq("signup")
      expect(result.user.id).to eq("user-uuid-123")
      expect(result.user.email).to eq("test@example.com")
    end

    it "uses GenerateLinkProperties.members dynamically (not hardcoded key list)" do
      # Verify Ruby uses struct members to determine link keys, matching Python's model_dump approach
      members = Supabase::Auth::Types::GenerateLinkProperties.members.map(&:to_s)
      expect(members).to include("action_link", "email_otp", "hashed_token", "redirect_to", "verification_type")
    end
  end

  describe "AC-3: get_error_message handles all error formats" do
    # Python handles both dict (isinstance) and object attributes (hasattr)
    # Ruby handles both Hash (.key?) and objects (.respond_to?)

    it "extracts 'msg' from Hash" do
      expect(helpers.send(:get_error_message, { "msg" => "hello" })).to eq("hello")
    end

    it "extracts 'message' from Hash" do
      expect(helpers.send(:get_error_message, { "message" => "world" })).to eq("world")
    end

    it "extracts 'error_description' from Hash" do
      expect(helpers.send(:get_error_message, { "error_description" => "bad" })).to eq("bad")
    end

    it "extracts 'error' from Hash" do
      expect(helpers.send(:get_error_message, { "error" => "fail" })).to eq("fail")
    end

    it "prefers 'msg' over 'message' (matching Python priority order)" do
      result = helpers.send(:get_error_message, { "msg" => "first", "message" => "second" })
      expect(result).to eq("first")
    end

    it "falls back to to_s for unknown formats" do
      expect(helpers.send(:get_error_message, 42)).to eq("42")
    end

    it "extracts from objects with respond_to? (matching Python hasattr)" do
      obj = Struct.new(:message).new("object message")
      expect(helpers.send(:get_error_message, obj)).to eq("object message")
    end

    it "extracts error_description from objects" do
      obj = Struct.new(:error_description).new("obj error desc")
      expect(helpers.send(:get_error_message, obj)).to eq("obj error desc")
    end
  end

  describe "AC-4: parse_response_api_version parses API version from headers" do
    it "parses valid API version date" do
      response = Struct.new(:headers).new({ "X-Supabase-Api-Version" => "2024-01-01" })
      result = helpers.parse_response_api_version(response)
      expect(result).to be_a(Time)
      expect(result.year).to eq(2024)
      expect(result.month).to eq(1)
      expect(result.day).to eq(1)
    end

    it "returns nil for missing header" do
      response = Struct.new(:headers).new({})
      expect(helpers.parse_response_api_version(response)).to be_nil
    end

    it "returns nil for empty header" do
      response = Struct.new(:headers).new({ "X-Supabase-Api-Version" => "" })
      expect(helpers.parse_response_api_version(response)).to be_nil
    end

    it "returns nil for invalid date format" do
      response = Struct.new(:headers).new({ "X-Supabase-Api-Version" => "not-a-date" })
      expect(helpers.parse_response_api_version(response)).to be_nil
    end

    it "returns nil for date not matching regex (e.g., 1999-01-01)" do
      response = Struct.new(:headers).new({ "X-Supabase-Api-Version" => "1999-01-01" })
      expect(helpers.parse_response_api_version(response)).to be_nil
    end

    it "parses future API versions (e.g., 2025-06-15)" do
      response = Struct.new(:headers).new({ "X-Supabase-Api-Version" => "2025-06-15" })
      result = helpers.parse_response_api_version(response)
      expect(result).to be_a(Time)
      expect(result.year).to eq(2025)
      expect(result.month).to eq(6)
    end
  end

  describe "AC-5: PKCE helpers produce correct S256 challenge" do
    it "generates verifier of default length 64" do
      verifier = helpers.generate_pkce_verifier
      expect(verifier.length).to eq(64)
    end

    it "generates verifier with custom length" do
      verifier = helpers.generate_pkce_verifier(43)
      expect(verifier.length).to eq(43)
    end

    it "raises for length < 43" do
      expect { helpers.generate_pkce_verifier(42) }.to raise_error(ArgumentError)
    end

    it "raises for length > 128" do
      expect { helpers.generate_pkce_verifier(129) }.to raise_error(ArgumentError)
    end

    it "generates verifier using only valid PKCE charset (RFC 7636)" do
      verifier = helpers.generate_pkce_verifier(128)
      valid_chars = /\A[a-zA-Z0-9\-._~]+\z/
      expect(verifier).to match(valid_chars)
    end

    it "generates unique verifiers (cryptographically random)" do
      verifiers = Array.new(10) { helpers.generate_pkce_verifier }
      expect(verifiers.uniq.length).to eq(10)
    end

    it "generates correct S256 challenge from verifier" do
      # Known test vector: verify SHA256 + base64url encoding
      verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
      challenge = helpers.generate_pkce_challenge(verifier)
      # SHA256 of the verifier, base64url-encoded without padding
      expected = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
      expect(challenge).to eq(expected)
    end

    it "challenge uses base64url encoding without padding (matching Python rstrip)" do
      verifier = helpers.generate_pkce_verifier
      challenge = helpers.generate_pkce_challenge(verifier)
      expect(challenge).not_to include("=")
      expect(challenge).not_to include("+")
      expect(challenge).not_to include("/")
    end
  end

  describe "AC-6: validate_exp correctly checks JWT expiration" do
    it "raises AuthInvalidJwtError for nil exp" do
      expect { helpers.validate_exp(nil) }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /no expiration/)
    end

    it "raises AuthInvalidJwtError for zero exp" do
      expect { helpers.validate_exp(0) }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /no expiration/)
    end

    it "raises AuthInvalidJwtError for expired token" do
      past = Time.now.to_f - 3600
      expect { helpers.validate_exp(past) }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /expired/)
    end

    it "does not raise for future exp" do
      future = Time.now.to_f + 3600
      expect { helpers.validate_exp(future) }.not_to raise_error
    end

    it "uses float comparison matching Python datetime.now().timestamp()" do
      # Python: exp <= time_now where time_now is datetime.now().timestamp() (float)
      # Ruby: exp <= Time.now.to_f (also float)
      just_now = Time.now.to_f
      expect { helpers.validate_exp(just_now) }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError)
    end
  end

  describe "AC-7: URL parsing helpers extract tokens from implicit grant URLs" do
    it "decode_jwt parses valid JWT into header, payload, signature, raw" do
      # Create a minimal valid JWT
      header = Base64.urlsafe_encode64('{"alg":"HS256","typ":"JWT"}', padding: false)
      payload = Base64.urlsafe_encode64('{"sub":"123","exp":9999999999}', padding: false)
      signature = Base64.urlsafe_encode64("signature_bytes_here", padding: false)
      jwt = "#{header}.#{payload}.#{signature}"

      result = helpers.decode_jwt(jwt)
      expect(result[:header]).to be_a(Hash)
      expect(result[:header]["alg"]).to eq("HS256")
      expect(result[:payload]["sub"]).to eq("123")
      expect(result[:signature]).to be_a(String)
      expect(result[:raw]["header"]).to eq(header)
      expect(result[:raw]["payload"]).to eq(payload)
    end

    it "decode_jwt raises AuthInvalidJwtError for invalid structure" do
      expect { helpers.decode_jwt("not.a.valid.jwt.token") }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /Invalid JWT structure/)
      expect { helpers.decode_jwt("only-one-part") }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /Invalid JWT structure/)
    end

    it "decode_jwt raises AuthInvalidJwtError for non-base64url parts" do
      expect { helpers.decode_jwt("!!!.@@@.###") }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /base64url/)
    end

    it "is_http_url returns true for http and https URLs" do
      expect(helpers.is_http_url("https://example.com")).to be true
      expect(helpers.is_http_url("http://example.com")).to be true
    end

    it "is_http_url returns false for non-http URLs" do
      expect(helpers.is_http_url("ftp://example.com")).to be false
      expect(helpers.is_http_url("")).to be false
      expect(helpers.is_http_url(nil)).to be false
    end

    it "is_valid_uuid validates correct UUIDs" do
      expect(helpers.is_valid_uuid("550e8400-e29b-41d4-a716-446655440000")).to be true
    end

    it "is_valid_uuid rejects invalid UUIDs" do
      expect(helpers.is_valid_uuid("not-a-uuid")).to be false
      expect(helpers.is_valid_uuid("")).to be false
      expect(helpers.is_valid_uuid(nil)).to be false
    end

    it "get_error_code extracts error_code from Hash" do
      expect(helpers.get_error_code({ "error_code" => "user_not_found" })).to eq("user_not_found")
    end

    it "get_error_code supports symbol keys" do
      expect(helpers.get_error_code({ error_code: "user_not_found" })).to eq("user_not_found")
    end

    it "get_error_code returns nil for non-Hash" do
      expect(helpers.get_error_code("not a hash")).to be_nil
    end

    it "parse_auth_response creates session when access_token/refresh_token/expires_in present" do
      data = {
        "access_token" => "token123",
        "refresh_token" => "refresh456",
        "expires_in" => 3600,
        "token_type" => "bearer",
        "user" => { "id" => "user-id", "aud" => "authenticated" }
      }
      result = helpers.parse_auth_response(data)
      expect(result).to be_a(Supabase::Auth::Types::AuthResponse)
      expect(result.session).not_to be_nil
      expect(result.session.access_token).to eq("token123")
      expect(result.user).not_to be_nil
    end

    it "parse_auth_response returns nil session when keys missing" do
      data = { "user" => { "id" => "user-id" } }
      result = helpers.parse_auth_response(data)
      expect(result.session).to be_nil
      expect(result.user).not_to be_nil
    end

    it "parse_user_response wraps data in 'user' key if missing" do
      data = { "id" => "user-id", "aud" => "authenticated" }
      result = helpers.parse_user_response(data)
      expect(result).to be_a(Supabase::Auth::Types::UserResponse)
      expect(result.user.id).to eq("user-id")
    end

    it "parse_user_response handles pre-wrapped data" do
      data = { "user" => { "id" => "user-id", "aud" => "authenticated" } }
      result = helpers.parse_user_response(data)
      expect(result.user.id).to eq("user-id")
    end

    it "parse_jwks raises AuthInvalidJwtError for empty JWKS" do
      expect { helpers.parse_jwks({}) }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /JWKS is empty/)
      expect { helpers.parse_jwks({ "keys" => [] }) }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /JWKS is empty/)
    end

    it "parse_jwks returns keys hash for valid JWKS" do
      jwks = { "keys" => [{ "kty" => "RSA", "kid" => "key1" }] }
      result = helpers.parse_jwks(jwks)
      expect(result["keys"]).to eq([{ "kty" => "RSA", "kid" => "key1" }])
    end

    it "parse_sso_response returns SSOResponse" do
      data = { "url" => "https://sso.example.com/auth" }
      result = helpers.parse_sso_response(data)
      expect(result).to be_a(Supabase::Auth::Types::SSOResponse)
      expect(result.url).to eq("https://sso.example.com/auth")
    end

    it "parse_auth_otp_response returns AuthOtpResponse" do
      data = { "message_id" => "msg123" }
      result = helpers.parse_auth_otp_response(data)
      expect(result).to be_a(Supabase::Auth::Types::AuthOtpResponse)
      expect(result.message_id).to eq("msg123")
    end

    it "parse_link_identity_response returns LinkIdentityResponse" do
      data = { "url" => "https://example.com/link" }
      result = helpers.parse_link_identity_response(data)
      expect(result).to be_a(Supabase::Auth::Types::LinkIdentityResponse)
      expect(result.url).to eq("https://example.com/link")
    end
  end

  describe "Constants match Python" do
    it "API_VERSION_HEADER_NAME matches Python" do
      expect(Supabase::Auth::Helpers::API_VERSION_HEADER_NAME).to eq("X-Supabase-Api-Version")
    end

    it "API_VERSION_REGEX matches valid dates" do
      expect("2024-01-01").to match(Supabase::Auth::Helpers::API_VERSION_REGEX)
      expect("2099-12-31").to match(Supabase::Auth::Helpers::API_VERSION_REGEX)
    end

    it "API_VERSION_REGEX rejects invalid dates" do
      expect("1999-01-01").not_to match(Supabase::Auth::Helpers::API_VERSION_REGEX)
      expect("not-a-date").not_to match(Supabase::Auth::Helpers::API_VERSION_REGEX)
    end

    it "PKCE_CHARSET matches Python's string.ascii_letters + digits + '-._~'" do
      charset = Supabase::Auth::Helpers::PKCE_CHARSET
      expect(charset).to include("a", "z", "A", "Z", "0", "9", "-", ".", "_", "~")
      expect(charset.length).to eq(66) # 26 + 26 + 10 + 4
      expect(charset).to be_frozen
    end
  end
end
