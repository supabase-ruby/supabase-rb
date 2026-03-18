# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

RSpec.describe Supabase::Auth::Helpers do
  # ── Error Handling Tests (10) ──────────────────────────────────────────

  # auth-py: test_handle_exception_with_api_version_and_error_code
  describe ".handle_exception" do
    it "returns AuthApiError with error code from AuthApiError exception" do
      error = Supabase::Auth::Errors::AuthApiError.new("Error code message", status: 400, code: "error_code")
      # Wrap in Faraday error to match handle_exception contract
      stub_request(:get, "http://localhost/hello-world")
        .to_return(status: 400, body: '{"message":"Error code message","error_code":"error_code"}',
                   headers: { "Content-Type" => "application/json" })

      faraday = Faraday.new("http://localhost") { |f| f.response :raise_error }
      begin
        faraday.get("/hello-world")
      rescue Faraday::ClientError => e
        result = described_class.handle_exception(e)
        expect(result).to be_a(Supabase::Auth::Errors::AuthApiError)
        expect(result.message).to eq("Error code message")
        expect(result.code).to eq("error_code")
      end
    end

    # auth-py: test_handle_exception_without_api_version_and_weak_password_error_code
    it "returns AuthWeakPassword with weak_password error code" do
      stub_request(:get, "http://localhost/hello-world")
        .to_return(status: 400,
                   body: '{"message":"Error code message","error_code":"weak_password","weak_password":{"reasons":["characters"]}}',
                   headers: { "Content-Type" => "application/json" })

      faraday = Faraday.new("http://localhost") { |f| f.response :raise_error }
      begin
        faraday.get("/hello-world")
      rescue Faraday::ClientError => e
        result = described_class.handle_exception(e)
        expect(result).to be_a(Supabase::Auth::Errors::AuthWeakPassword)
        expect(result.message).to eq("Error code message")
        expect(result.code).to eq("weak_password")
      end
    end

    # auth-py: test_handle_exception_with_api_version_2024_01_01_and_error_code
    it "returns AuthApiError with error code from API version 2024-01-01 response" do
      stub_request(:get, "http://localhost/hello-world")
        .to_return(status: 400,
                   body: '{"message":"Error code message","code":"error_code"}',
                   headers: { "Content-Type" => "application/json",
                              "X-Supabase-Api-Version" => "2024-01-01" })

      faraday = Faraday.new("http://localhost") { |f| f.response :raise_error }
      begin
        faraday.get("/hello-world")
      rescue Faraday::ClientError => e
        result = described_class.handle_exception(e)
        expect(result).to be_a(Supabase::Auth::Errors::AuthApiError)
        expect(result.message).to eq("Error code message")
        expect(result.code).to eq("error_code")
      end
    end

    # auth-py: test_handle_exception_non_http_error
    it "returns AuthRetryableError for non-HTTP errors" do
      exception = ValueError.new("Test error") rescue StandardError.new("Test error")
      result = described_class.handle_exception(exception)

      expect(result).to be_a(Supabase::Auth::Errors::AuthRetryableError)
      expect(result.message).to eq("Test error")
      expect(result.status).to eq(0)
    end

    # auth-py: test_handle_exception_network_error
    it "returns AuthRetryableError for 503 network errors" do
      stub_request(:get, "http://localhost/hello-world")
        .to_return(status: 503, body: "Service Unavailable")

      faraday = Faraday.new("http://localhost") { |f| f.response :raise_error }
      begin
        faraday.get("/hello-world")
      rescue Faraday::ServerError => e
        result = described_class.handle_exception(e)
        expect(result).to be_a(Supabase::Auth::Errors::AuthRetryableError)
        expect(result.status).to eq(503)
      end
    end

    # auth-py: test_handle_exception_with_weak_password_attribute
    it "returns AuthApiError when error_code is nil and no weak_password dict" do
      stub_request(:get, "http://localhost/hello-world")
        .to_return(status: 400,
                   body: '{"message":"Invalid request","error_description":"Something went wrong"}',
                   headers: { "Content-Type" => "application/json" })

      faraday = Faraday.new("http://localhost") { |f| f.response :raise_error }
      begin
        faraday.get("/hello-world")
      rescue Faraday::ClientError => e
        result = described_class.handle_exception(e)
        expect(result).to be_a(Supabase::Auth::Errors::AuthApiError)
        expect(result.message).to eq("Invalid request")
        expect(result.status).to eq(400)
        expect(result.code).to be_nil
      end
    end

    # auth-py: test_handle_exception_weak_password_with_error_code
    it "returns AuthWeakPassword when error_code is weak_password with reasons" do
      stub_request(:get, "http://localhost/hello-world")
        .to_return(status: 400,
                   body: '{"message":"Password too weak","error_code":"weak_password","weak_password":{"reasons":["Password too simple"]}}',
                   headers: { "Content-Type" => "application/json" })

      faraday = Faraday.new("http://localhost") { |f| f.response :raise_error }
      begin
        faraday.get("/hello-world")
      rescue Faraday::ClientError => e
        result = described_class.handle_exception(e)
        expect(result).to be_a(Supabase::Auth::Errors::AuthWeakPassword)
        expect(result.message).to eq("Password too weak")
        expect(result.status).to eq(400)
        expect(result.reasons).to eq(["Password too simple"])
      end
    end

    # auth-py: test_handle_exception_with_new_api_version
    it "returns AuthWeakPassword for new API version with code field" do
      stub_request(:get, "http://localhost/hello-world")
        .to_return(status: 400,
                   body: '{"message":"Password too weak","code":"weak_password","weak_password":{"reasons":["Password too simple"]}}',
                   headers: { "Content-Type" => "application/json",
                              "X-Supabase-Api-Version" => "2024-01-02" })

      faraday = Faraday.new("http://localhost") { |f| f.response :raise_error }
      begin
        faraday.get("/hello-world")
      rescue Faraday::ClientError => e
        result = described_class.handle_exception(e)
        expect(result).to be_a(Supabase::Auth::Errors::AuthWeakPassword)
        expect(result.message).to eq("Password too weak")
        expect(result.status).to eq(400)
      end
    end

    # auth-py: test_handle_exception_unknown_error
    it "returns AuthUnknownError when response JSON is unparseable" do
      stub_request(:get, "http://localhost/hello-world")
        .to_return(status: 500, body: "not json at all{{{",
                   headers: { "Content-Type" => "text/plain" })

      faraday = Faraday.new("http://localhost") { |f| f.response :raise_error }
      begin
        faraday.get("/hello-world")
      rescue Faraday::ServerError => e
        result = described_class.handle_exception(e)
        expect(result).to be_a(Supabase::Auth::Errors::AuthUnknownError)
        expect(result.message).to include("Server error").or include("the server responded with status 500")
      end
    end

    # auth-py: test_handle_exception_weak_password_branch
    # Python test monkey-patches isinstance to make weak_password appear as both dict and list,
    # testing an otherwise unreachable branch. In Ruby, we test the same code path by providing
    # a weak_password dict with reasons — the implementation should detect "weak_password" in
    # the response and return AuthWeakPasswordError regardless of error_code presence.
    it "returns AuthWeakPassword when weak_password dict has reasons (branch coverage)" do
      stub_request(:get, "http://localhost/hello-world")
        .to_return(status: 400,
                   body: '{"message":"Password too weak","weak_password":{"reasons":["Password too short"]}}',
                   headers: { "Content-Type" => "application/json" })

      faraday = Faraday.new("http://localhost") { |f| f.response :raise_error }
      begin
        faraday.get("/hello-world")
      rescue Faraday::ClientError => e
        result = described_class.handle_exception(e)
        expect(result).to be_a(Supabase::Auth::Errors::AuthWeakPassword)
        expect(result.message).to eq("Password too weak")
        expect(result.status).to eq(400)
        expect(result.reasons).to eq(["Password too short"])
      end
    end
  end

  # ── JWT and PKCE Tests (6) ─────────────────────────────────────────────

  # auth-py: test_decode_jwt
  describe ".decode_jwt" do
    it "decodes a valid JWT" do
      token = mock_access_token
      result = described_class.decode_jwt(token)
      expect(result).to be_a(Hash)
      expect(result[:header]).to be_a(Hash)
      expect(result[:payload]).to be_a(Hash)
      expect(result[:payload]["sub"]).to eq("1234567890")
    end

    it "raises AuthInvalidJwtError for invalid JWT" do
      expect { described_class.decode_jwt("non-valid-jwt") }
        .to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /Invalid JWT structure/)
    end
  end

  # auth-py: test_generate_pkce_verifier
  describe ".generate_pkce_verifier" do
    it "generates a string verifier of specified length" do
      result = described_class.generate_pkce_verifier(45)
      expect(result).to be_a(String)
      expect(result.length).to eq(45)
    end

    it "raises ArgumentError for length below 43" do
      expect { described_class.generate_pkce_verifier(42) }
        .to raise_error(ArgumentError, /PKCE verifier length must be between 43 and 128 characters/)
    end
  end

  # auth-py: test_generate_pkce_challenge
  describe ".generate_pkce_challenge" do
    it "generates a challenge string from a verifier" do
      verifier = described_class.generate_pkce_verifier(45)
      result = described_class.generate_pkce_challenge(verifier)
      expect(result).to be_a(String)
      expect(result).not_to be_empty
    end
  end

  # auth-py: test_validate_exp_with_no_exp
  describe ".validate_exp" do
    it "raises AuthInvalidJwtError when exp is nil" do
      expect { described_class.validate_exp(nil) }
        .to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /JWT has no expiration time/)
    end

    # auth-py: test_validate_exp_with_expired_exp
    it "raises AuthInvalidJwtError when exp is in the past" do
      exp = Time.now.to_i - 3600
      expect { described_class.validate_exp(exp) }
        .to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /JWT has expired/)
    end

    # auth-py: test_validate_exp_with_valid_exp
    it "does not raise when exp is in the future" do
      exp = Time.now.to_i + 3600
      expect { described_class.validate_exp(exp) }.not_to raise_error
    end
  end

  # ── Response Parsing Tests (12) ────────────────────────────────────────

  # auth-py: test_parse_response_api_version_with_valid_date
  describe ".parse_response_api_version" do
    it "parses valid date from response header" do
      response = instance_double(Faraday::Response, headers: { "X-Supabase-Api-Version" => "2024-01-01" })
      result = described_class.parse_response_api_version(response)
      expect(result).to be_a(Time)
      expect(result.year).to eq(2024)
      expect(result.month).to eq(1)
      expect(result.day).to eq(1)
    end

    # auth-py: test_parse_response_api_version_with_invalid_dates
    it "returns nil for invalid dates" do
      dates = ["2024-01-32", "", "notadate", "Sat Feb 24 2024 17:59:17 GMT+0100"]
      dates.each do |date|
        response = instance_double(Faraday::Response, headers: { "X-Supabase-Api-Version" => date })
        result = described_class.parse_response_api_version(response)
        expect(result).to be_nil, "Expected nil for date '#{date}'"
      end
    end

    # auth-py: test_parse_response_api_version_invalid_date (mock-based)
    it "returns nil for invalid date 2023-02-30" do
      response = instance_double(Faraday::Response, headers: { "X-Supabase-Api-Version" => "2023-02-30" })
      result = described_class.parse_response_api_version(response)
      expect(result).to be_nil
    end
  end

  # auth-py: test_parse_auth_response_with_session
  describe ".parse_auth_response" do
    it "parses response with session data" do
      data = {
        "access_token" => "test_access_token",
        "refresh_token" => "test_refresh_token",
        "expires_in" => 3600,
        "user" => {
          "id" => "user-123",
          "email" => "test@example.com"
        }
      }
      result = described_class.parse_auth_response(data)
      expect(result).to be_a(Supabase::Auth::Types::AuthResponse)
      expect(result.session).not_to be_nil
      expect(result.session.access_token).to eq("test_access_token")
      expect(result.user).not_to be_nil
    end

    # auth-py: test_parse_auth_response_without_session
    it "parses response without session data" do
      data = {
        "user" => {
          "id" => "user-123",
          "email" => "test@example.com"
        }
      }
      result = described_class.parse_auth_response(data)
      expect(result).to be_a(Supabase::Auth::Types::AuthResponse)
      expect(result.session).to be_nil
      expect(result.user).not_to be_nil
      expect(result.user.id).to eq("user-123")
    end
  end

  # auth-py: test_parse_link_response
  describe ".parse_link_response" do
    it "parses link response with properties and user" do
      data = {
        "action_link" => "https://example.com/verify",
        "email_otp" => "123456",
        "hashed_token" => "abc123",
        "redirect_to" => "https://example.com/app",
        "verification_type" => "signup",
        "id" => "user-123",
        "email" => "test@example.com"
      }
      result = described_class.parse_link_response(data)
      expect(result).to be_a(Supabase::Auth::Types::GenerateLinkResponse)
      expect(result.properties.action_link).to eq("https://example.com/verify")
      expect(result.properties.email_otp).to eq("123456")
      expect(result.user).not_to be_nil
    end
  end

  # auth-py: test_parse_user_response_with_user_object
  describe ".parse_user_response" do
    it "parses data with user key" do
      data = { "user" => { "id" => "user-123", "email" => "test@example.com" } }
      result = described_class.parse_user_response(data)
      expect(result).to be_a(Supabase::Auth::Types::UserResponse)
      expect(result.user).not_to be_nil
      expect(result.user.id).to eq("user-123")
    end

    # auth-py: test_parse_user_response_without_user_object
    it "wraps data without user key" do
      data = { "id" => "user-123", "email" => "test@example.com" }
      result = described_class.parse_user_response(data)
      expect(result).to be_a(Supabase::Auth::Types::UserResponse)
      expect(result.user).not_to be_nil
      expect(result.user.id).to eq("user-123")
    end
  end

  # auth-py: test_parse_sso_response
  describe ".parse_sso_response" do
    it "parses SSO response data" do
      result = described_class.parse_sso_response({ "url" => "https://provider.com/auth" })
      expect(result).to be_a(Supabase::Auth::Types::SSOResponse)
      expect(result.url).to eq("https://provider.com/auth")
    end
  end

  # auth-py: test_parse_link_identity_response
  describe ".parse_link_identity_response" do
    it "parses link identity response" do
      result = described_class.parse_link_identity_response({ "url" => "http://localhost/hello-world" })
      expect(result).to be_a(Supabase::Auth::Types::LinkIdentityResponse)
      expect(result.url).to eq("http://localhost/hello-world")
    end
  end

  # auth-py: test_parse_jwks_empty_keys
  describe ".parse_jwks" do
    it "raises AuthInvalidJwtError for empty keys" do
      expect { described_class.parse_jwks({ "keys" => [] }) }
        .to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /JWKS is empty/)
    end
  end

  # auth-py: test_parse_auth_otp_response
  describe ".parse_auth_otp_response" do
    it "parses response with message_id" do
      result = described_class.parse_auth_otp_response({ "message_id" => "12345" })
      expect(result).to be_a(Supabase::Auth::Types::AuthOtpResponse)
      expect(result.message_id).to eq("12345")
      expect(result.user).to be_nil
      expect(result.session).to be_nil
    end

    it "parses response without message_id" do
      result = described_class.parse_auth_otp_response({})
      expect(result).to be_a(Supabase::Auth::Types::AuthOtpResponse)
      expect(result.message_id).to be_nil
      expect(result.user).to be_nil
      expect(result.session).to be_nil
    end
  end

  # ── Misc Tests (2) ────────────────────────────────────────────────────

  # auth-py: test_get_error_code
  describe ".get_error_code" do
    it "returns nil for empty hash" do
      expect(described_class.get_error_code({})).to be_nil
    end

    it "returns error_code when present" do
      expect(described_class.get_error_code({ "error_code" => "500" })).to eq("500")
    end
  end

  # auth-py: test_is_http_url
  describe ".is_http_url" do
    it "returns true for valid HTTP/HTTPS URLs" do
      expect(described_class.is_http_url("http://example.com")).to be true
      expect(described_class.is_http_url("https://example.com")).to be true
      expect(described_class.is_http_url("https://example.com/path?query=value#fragment")).to be true
    end

    it "returns false for invalid or non-HTTP URLs" do
      expect(described_class.is_http_url("ftp://example.com")).to be false
      expect(described_class.is_http_url("file:///path/to/file.txt")).to be false
      expect(described_class.is_http_url("example.com")).to be false
      expect(described_class.is_http_url("")).to be false
      expect(described_class.is_http_url("not a url")).to be false
    end
  end

  # ── 3 Pydantic-specific tests are skipped ─────────────────────────────
  # test_model_validate_pydantic_v1 — Pydantic-specific, not applicable to Ruby
  # test_model_dump_pydantic_v1 — Pydantic-specific, not applicable to Ruby
  # test_model_dump_json_pydantic_v1 — Pydantic-specific, not applicable to Ruby
end
