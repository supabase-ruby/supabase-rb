# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

# US-007: Audit Error Handling
# Verifies error classes, error codes, and error handling logic match the Python SDK.
RSpec.describe "US-007: Error Handling Audit" do
  describe "AC-1: Error hierarchy matches Python" do
    # Python hierarchy:
    # AuthError > AuthApiError, AuthUnknownError, CustomAuthError
    # CustomAuthError > AuthSessionMissingError, AuthInvalidCredentialsError,
    #   AuthImplicitGrantRedirectError, AuthRetryableError, AuthWeakPasswordError, AuthInvalidJwtError

    it "AuthError inherits from StandardError (Python: Exception)" do
      expect(Supabase::Auth::Errors::AuthError).to be < StandardError
    end

    it "AuthApiError inherits from AuthError" do
      expect(Supabase::Auth::Errors::AuthApiError).to be < Supabase::Auth::Errors::AuthError
    end

    it "AuthUnknownError inherits from AuthError" do
      expect(Supabase::Auth::Errors::AuthUnknownError).to be < Supabase::Auth::Errors::AuthError
    end

    it "CustomAuthError inherits from AuthError" do
      expect(Supabase::Auth::Errors::CustomAuthError).to be < Supabase::Auth::Errors::AuthError
    end

    it "AuthSessionMissingError inherits from CustomAuthError" do
      expect(Supabase::Auth::Errors::AuthSessionMissing).to be < Supabase::Auth::Errors::CustomAuthError
    end

    it "AuthInvalidCredentialsError inherits from CustomAuthError" do
      expect(Supabase::Auth::Errors::AuthInvalidCredentialsError).to be < Supabase::Auth::Errors::CustomAuthError
    end

    it "AuthImplicitGrantRedirectError inherits from CustomAuthError" do
      expect(Supabase::Auth::Errors::AuthImplicitGrantRedirectError).to be < Supabase::Auth::Errors::CustomAuthError
    end

    it "AuthRetryableError inherits from CustomAuthError" do
      expect(Supabase::Auth::Errors::AuthRetryableError).to be < Supabase::Auth::Errors::CustomAuthError
    end

    it "AuthWeakPasswordError inherits from CustomAuthError" do
      expect(Supabase::Auth::Errors::AuthWeakPassword).to be < Supabase::Auth::Errors::CustomAuthError
    end

    it "AuthInvalidJwtError inherits from CustomAuthError" do
      expect(Supabase::Auth::Errors::AuthInvalidJwtError).to be < Supabase::Auth::Errors::CustomAuthError
    end
  end

  describe "AC-2: AuthApiError includes status and code fields" do
    it "stores status and code" do
      error = Supabase::Auth::Errors::AuthApiError.new("Not found", status: 404, code: "user_not_found")
      expect(error.status).to eq(404)
      expect(error.code).to eq("user_not_found")
      expect(error.message).to eq("Not found")
    end

    it "defaults code to nil when not provided" do
      error = Supabase::Auth::Errors::AuthApiError.new("Error", status: 500)
      expect(error.code).to be_nil
    end

    it "to_h includes message, status, and code matching Python's to_dict" do
      error = Supabase::Auth::Errors::AuthApiError.new("Test", status: 400, code: "bad_json")
      h = error.to_h
      expect(h).to include(message: "Test", status: 400, code: "bad_json")
    end
  end

  describe "AC-3: AuthWeakPassword includes reasons array" do
    it "stores reasons array" do
      error = Supabase::Auth::Errors::AuthWeakPassword.new(
        "Password too weak",
        status: 422,
        reasons: ["too short", "no special chars"]
      )
      expect(error.reasons).to eq(["too short", "no special chars"])
      expect(error.code).to eq("weak_password")
      expect(error.status).to eq(422)
      expect(error.name).to eq("AuthWeakPasswordError")
    end

    it "defaults reasons to empty array" do
      error = Supabase::Auth::Errors::AuthWeakPassword.new("Weak")
      expect(error.reasons).to eq([])
    end

    it "to_h includes reasons" do
      error = Supabase::Auth::Errors::AuthWeakPassword.new("Weak", reasons: ["too short"])
      expect(error.to_h).to include(reasons: ["too short"])
    end
  end

  describe "AC-4: AuthRetryableError triggered on 502/503/504 status codes" do
    [502, 503, 504].each do |status|
      it "handle_exception returns AuthRetryableError for HTTP #{status}" do
        response = { status: status, headers: {}, body: "Server Error" }
        exception = Faraday::ServerError.new("server error", response)

        result = Supabase::Auth::Helpers.handle_exception(exception)
        expect(result).to be_a(Supabase::Auth::Errors::AuthRetryableError)
        expect(result.status).to eq(status)
      end
    end

    it "handle_exception returns AuthRetryableError for non-HTTP exceptions" do
      exception = RuntimeError.new("Connection refused")
      result = Supabase::Auth::Helpers.handle_exception(exception)
      expect(result).to be_a(Supabase::Auth::Errors::AuthRetryableError)
      expect(result.status).to eq(0)
    end

    it "does NOT return AuthRetryableError for 400/401/403/404/500" do
      [400, 401, 403, 404, 500].each do |status|
        body = { "message" => "Error", "error_code" => "test" }.to_json
        response = { status: status, headers: {}, body: body }
        klass = status >= 500 ? Faraday::ServerError : Faraday::ClientError
        exception = klass.new("error", response)

        result = Supabase::Auth::Helpers.handle_exception(exception)
        expect(result).to be_a(Supabase::Auth::Errors::AuthApiError)
        expect(result).not_to be_a(Supabase::Auth::Errors::AuthRetryableError)
      end
    end
  end

  describe "AC-5: Error code extraction matches Python's logic" do
    let(:api_version_header) { "2024-01-01" }
    let(:old_api_version_header) { "2023-12-31" }

    it "extracts error code from 'code' field when API version >= 2024-01-01" do
      body = { "code" => "user_not_found", "message" => "User not found" }.to_json
      response = {
        status: 404,
        headers: { "X-Supabase-Api-Version" => api_version_header },
        body: body
      }
      exception = Faraday::ClientError.new("error", response)

      result = Supabase::Auth::Helpers.handle_exception(exception)
      expect(result).to be_a(Supabase::Auth::Errors::AuthApiError)
      expect(result.code).to eq("user_not_found")
    end

    it "falls back to 'error_code' field when API version < 2024-01-01" do
      body = { "error_code" => "user_not_found", "message" => "User not found" }.to_json
      response = {
        status: 404,
        headers: { "X-Supabase-Api-Version" => old_api_version_header },
        body: body
      }
      exception = Faraday::ClientError.new("error", response)

      result = Supabase::Auth::Helpers.handle_exception(exception)
      expect(result).to be_a(Supabase::Auth::Errors::AuthApiError)
      expect(result.code).to eq("user_not_found")
    end

    it "falls back to 'error_code' field when no API version header" do
      body = { "error_code" => "bad_jwt", "message" => "Invalid token" }.to_json
      response = { status: 401, headers: {}, body: body }
      exception = Faraday::ClientError.new("error", response)

      result = Supabase::Auth::Helpers.handle_exception(exception)
      expect(result.code).to eq("bad_jwt")
    end

    it "ignores 'code' field when API version < 2024-01-01 (uses error_code instead)" do
      body = { "code" => "should_ignore", "error_code" => "bad_jwt", "message" => "Test" }.to_json
      response = {
        status: 401,
        headers: { "X-Supabase-Api-Version" => old_api_version_header },
        body: body
      }
      exception = Faraday::ClientError.new("error", response)

      result = Supabase::Auth::Helpers.handle_exception(exception)
      expect(result.code).to eq("bad_jwt")
    end

    it "returns nil code when no error code field present" do
      body = { "message" => "Something failed" }.to_json
      response = { status: 400, headers: {}, body: body }
      exception = Faraday::ClientError.new("error", response)

      result = Supabase::Auth::Helpers.handle_exception(exception)
      expect(result.code).to be_nil
    end

    it "extracts weak_password error with reasons from error_code" do
      body = {
        "code" => "weak_password",
        "message" => "Password too weak",
        "weak_password" => { "reasons" => ["too short", "no digits"] }
      }.to_json
      response = {
        status: 422,
        headers: { "X-Supabase-Api-Version" => api_version_header },
        body: body
      }
      exception = Faraday::ClientError.new("error", response)

      result = Supabase::Auth::Helpers.handle_exception(exception)
      expect(result).to be_a(Supabase::Auth::Errors::AuthWeakPassword)
      expect(result.reasons).to eq(["too short", "no digits"])
      expect(result.status).to eq(422)
    end

    it "detects weak_password from response body even without error_code" do
      body = {
        "message" => "Password too weak",
        "weak_password" => { "reasons" => ["needs uppercase"] }
      }.to_json
      response = { status: 422, headers: {}, body: body }
      exception = Faraday::ClientError.new("error", response)

      result = Supabase::Auth::Helpers.handle_exception(exception)
      expect(result).to be_a(Supabase::Auth::Errors::AuthWeakPassword)
      expect(result.reasons).to eq(["needs uppercase"])
    end

    it "returns AuthUnknownError when response parsing fails" do
      response = { status: 400, headers: {}, body: "not json{{{" }
      exception = Faraday::ClientError.new("error", response)

      result = Supabase::Auth::Helpers.handle_exception(exception)
      expect(result).to be_a(Supabase::Auth::Errors::AuthUnknownError)
      expect(result.original_error).to be_a(JSON::ParserError)
    end
  end

  describe "AC-6: AuthPKCEError (Ruby-only enhancement)" do
    it "exists as a Ruby-only error not in Python" do
      expect(Supabase::Auth::Errors::AuthPKCEError).to be < Supabase::Auth::Errors::AuthError
      # It inherits directly from AuthError, not CustomAuthError
      expect(Supabase::Auth::Errors::AuthPKCEError).not_to be < Supabase::Auth::Errors::CustomAuthError
    end

    it "has status 400 and code pkce_error" do
      error = Supabase::Auth::Errors::AuthPKCEError.new("Code verifier mismatch")
      expect(error.status).to eq(400)
      expect(error.code).to eq("pkce_error")
    end
  end

  describe "AC-7: All error codes from Python are present in Ruby" do
    # The exact 81 error codes from Python's ErrorCode Literal type
    let(:python_error_codes) do
      %w[
        unexpected_failure validation_failed bad_json email_exists phone_exists
        bad_jwt not_admin no_authorization user_not_found session_not_found
        flow_state_not_found flow_state_expired signup_disabled user_banned
        provider_email_needs_verification invite_not_found bad_oauth_state
        bad_oauth_callback oauth_provider_not_supported unexpected_audience
        single_identity_not_deletable email_conflict_identity_not_deletable
        identity_already_exists email_provider_disabled phone_provider_disabled
        too_many_enrolled_mfa_factors mfa_factor_name_conflict mfa_factor_not_found
        mfa_ip_address_mismatch mfa_challenge_expired mfa_verification_failed
        mfa_verification_rejected insufficient_aal captcha_failed
        saml_provider_disabled manual_linking_disabled sms_send_failed
        email_not_confirmed phone_not_confirmed reauth_nonce_missing
        saml_relay_state_not_found saml_relay_state_expired saml_idp_not_found
        saml_assertion_no_user_id saml_assertion_no_email user_already_exists
        sso_provider_not_found saml_metadata_fetch_failed saml_idp_already_exists
        sso_domain_already_exists saml_entity_id_mismatch conflict provider_disabled
        user_sso_managed reauthentication_needed same_password
        reauthentication_not_valid otp_expired otp_disabled identity_not_found
        weak_password over_request_rate_limit over_email_send_rate_limit
        over_sms_send_rate_limit bad_code_verifier anonymous_provider_disabled
        hook_timeout hook_timeout_after_retry hook_payload_over_size_limit
        hook_payload_invalid_content_type request_timeout
        mfa_phone_enroll_not_enabled mfa_phone_verify_not_enabled
        mfa_totp_enroll_not_enabled mfa_totp_verify_not_enabled
        mfa_webauthn_enroll_not_enabled mfa_webauthn_verify_not_enabled
        mfa_verified_factor_exists invalid_credentials
        email_address_not_authorized email_address_invalid
      ]
    end

    it "has exactly 81 error codes matching Python" do
      expect(Supabase::Auth::Errors::ERROR_CODES.length).to eq(81)
    end

    it "contains every Python error code" do
      python_error_codes.each do |code|
        expect(Supabase::Auth::Errors::ERROR_CODES).to include(code),
          "Missing error code: #{code}"
      end
    end

    it "has no extra codes beyond Python's set" do
      extra = Supabase::Auth::Errors::ERROR_CODES - python_error_codes
      expect(extra).to be_empty, "Extra error codes not in Python: #{extra.join(', ')}"
    end

    it "ERROR_CODES is frozen" do
      expect(Supabase::Auth::Errors::ERROR_CODES).to be_frozen
    end
  end

  describe "get_error_message matches Python's logic" do
    it "extracts msg field first" do
      data = { "msg" => "from msg", "message" => "from message" }
      result = Supabase::Auth::Helpers.send(:get_error_message, data)
      expect(result).to eq("from msg")
    end

    it "falls back to message field" do
      data = { "message" => "from message", "error_description" => "from desc" }
      result = Supabase::Auth::Helpers.send(:get_error_message, data)
      expect(result).to eq("from message")
    end

    it "falls back to error_description field" do
      data = { "error_description" => "from desc", "error" => "from error" }
      result = Supabase::Auth::Helpers.send(:get_error_message, data)
      expect(result).to eq("from desc")
    end

    it "falls back to error field" do
      data = { "error" => "from error" }
      result = Supabase::Auth::Helpers.send(:get_error_message, data)
      expect(result).to eq("from error")
    end

    it "falls back to to_s for non-Hash" do
      result = Supabase::Auth::Helpers.send(:get_error_message, "raw string")
      expect(result).to eq("raw string")
    end

    it "handles objects with method-based access (matches Python hasattr path)" do
      obj = Struct.new(:message).new("from object message")
      result = Supabase::Auth::Helpers.send(:get_error_message, obj)
      expect(result).to eq("from object message")
    end
  end

  describe "Error class field parity with Python" do
    it "AuthSessionMissingError has correct defaults matching Python" do
      error = Supabase::Auth::Errors::AuthSessionMissing.new
      expect(error.message).to eq("Auth session missing!")
      expect(error.name).to eq("AuthSessionMissingError")
      expect(error.status).to eq(400)
    end

    it "AuthInvalidCredentialsError has correct name and status" do
      error = Supabase::Auth::Errors::AuthInvalidCredentialsError.new("Invalid")
      expect(error.name).to eq("AuthInvalidCredentialsError")
      expect(error.status).to eq(400)
    end

    it "AuthImplicitGrantRedirectError has correct name, status, and details" do
      details = { error: "access_denied", code: "403" }
      error = Supabase::Auth::Errors::AuthImplicitGrantRedirectError.new("Redirect error", details: details)
      expect(error.name).to eq("AuthImplicitGrantRedirectError")
      expect(error.status).to eq(500)
      expect(error.details).to eq(details)
      expect(error.to_h).to include(details: details)
    end

    it "AuthRetryableError has correct name and default status" do
      error = Supabase::Auth::Errors::AuthRetryableError.new("Network error")
      expect(error.name).to eq("AuthRetryableError")
      expect(error.status).to eq(0)
    end

    it "AuthInvalidJwtError has correct name, status, and code" do
      error = Supabase::Auth::Errors::AuthInvalidJwtError.new("JWT expired")
      expect(error.name).to eq("AuthInvalidJwtError")
      expect(error.status).to eq(400)
      expect(error.code).to eq("invalid_jwt")
    end

    it "AuthUnknownError wraps original error and has nil status/code" do
      original = RuntimeError.new("boom")
      error = Supabase::Auth::Errors::AuthUnknownError.new("Unknown", original_error: original)
      expect(error.original_error).to eq(original)
      expect(error.status).to be_nil
      expect(error.code).to be_nil
    end

    it "aliases match Python class names" do
      expect(Supabase::Auth::Errors::AuthSessionMissingError).to eq(Supabase::Auth::Errors::AuthSessionMissing)
      expect(Supabase::Auth::Errors::AuthWeakPasswordError).to eq(Supabase::Auth::Errors::AuthWeakPassword)
    end
  end
end
