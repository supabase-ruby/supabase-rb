# frozen_string_literal: true

RSpec.describe Supabase::Auth::Errors do
  describe Supabase::Auth::Errors::AuthError do
    it "inherits from StandardError" do
      expect(Supabase::Auth::Errors::AuthError).to be < StandardError
    end

    it "has status and code attributes" do
      error = described_class.new("something failed", status: 500, code: "unexpected_failure")
      expect(error.message).to eq("something failed")
      expect(error.status).to eq(500)
      expect(error.code).to eq("unexpected_failure")
    end

    it "defaults status and code to nil" do
      error = described_class.new("generic error")
      expect(error.status).to be_nil
      expect(error.code).to be_nil
    end
  end

  describe Supabase::Auth::Errors::AuthApiError do
    it "inherits from AuthError" do
      expect(described_class).to be < Supabase::Auth::Errors::AuthError
    end

    it "requires status and sets code" do
      error = described_class.new("Not found", status: 404, code: "user_not_found")
      expect(error.message).to eq("Not found")
      expect(error.status).to eq(404)
      expect(error.code).to eq("user_not_found")
    end

    it "defaults code to nil" do
      error = described_class.new("Server error", status: 500)
      expect(error.status).to eq(500)
      expect(error.code).to be_nil
    end
  end

  describe Supabase::Auth::Errors::AuthInvalidJwtError do
    it "inherits from AuthError" do
      expect(described_class).to be < Supabase::Auth::Errors::AuthError
    end

    it "sets status to 400 and code to invalid_jwt" do
      error = described_class.new("JWT expired")
      expect(error.message).to eq("JWT expired")
      expect(error.status).to eq(400)
      expect(error.code).to eq("invalid_jwt")
    end
  end

  describe Supabase::Auth::Errors::AuthSessionMissing do
    it "inherits from AuthError" do
      expect(described_class).to be < Supabase::Auth::Errors::AuthError
    end

    it "has a default message" do
      error = described_class.new
      expect(error.message).to eq("Auth session missing!")
      expect(error.status).to eq(400)
    end

    it "accepts a custom message" do
      error = described_class.new("No session found")
      expect(error.message).to eq("No session found")
    end
  end

  describe Supabase::Auth::Errors::AuthWeakPassword do
    it "inherits from AuthError" do
      expect(described_class).to be < Supabase::Auth::Errors::AuthError
    end

    it "has reasons attribute" do
      error = described_class.new("Password too weak", reasons: ["too short", "no special chars"])
      expect(error.message).to eq("Password too weak")
      expect(error.code).to eq("weak_password")
      expect(error.reasons).to eq(["too short", "no special chars"])
      expect(error.status).to eq(422)
    end

    it "defaults reasons to empty array" do
      error = described_class.new("Weak")
      expect(error.reasons).to eq([])
    end
  end

  describe Supabase::Auth::Errors::AuthPKCEError do
    it "inherits from AuthError" do
      expect(described_class).to be < Supabase::Auth::Errors::AuthError
    end

    it "sets status and code" do
      error = described_class.new("Code verifier mismatch")
      expect(error.message).to eq("Code verifier mismatch")
      expect(error.status).to eq(400)
      expect(error.code).to eq("pkce_error")
    end
  end

  describe Supabase::Auth::Errors::AuthRetryableError do
    it "inherits from CustomAuthError" do
      expect(described_class).to be < Supabase::Auth::Errors::CustomAuthError
    end

    it "sets name to AuthRetryableError and defaults status to 0" do
      error = described_class.new("Network timeout")
      expect(error.message).to eq("Network timeout")
      expect(error.name).to eq("AuthRetryableError")
      expect(error.status).to eq(0)
    end

    it "accepts a custom status code" do
      error = described_class.new("Service unavailable", status: 503)
      expect(error.status).to eq(503)
    end
  end

  describe Supabase::Auth::Errors::AuthInvalidCredentialsError do
    it "inherits from CustomAuthError" do
      expect(described_class).to be < Supabase::Auth::Errors::CustomAuthError
    end

    it "sets name and status 400" do
      error = described_class.new("Invalid login credentials")
      expect(error.message).to eq("Invalid login credentials")
      expect(error.name).to eq("AuthInvalidCredentialsError")
      expect(error.status).to eq(400)
    end
  end

  describe Supabase::Auth::Errors::AuthImplicitGrantRedirectError do
    it "inherits from CustomAuthError" do
      expect(described_class).to be < Supabase::Auth::Errors::CustomAuthError
    end

    it "sets name and status 500 with optional details" do
      error = described_class.new("Redirect error", details: { error: "access_denied", code: "403" })
      expect(error.message).to eq("Redirect error")
      expect(error.name).to eq("AuthImplicitGrantRedirectError")
      expect(error.status).to eq(500)
      expect(error.details).to eq({ error: "access_denied", code: "403" })
    end

    it "defaults details to nil" do
      error = described_class.new("Redirect failed")
      expect(error.details).to be_nil
    end

    it "includes details in to_h" do
      error = described_class.new("Error", details: { error: "test", code: "1" })
      hash = error.to_h
      expect(hash[:details]).to eq({ error: "test", code: "1" })
      expect(hash[:name]).to eq("AuthImplicitGrantRedirectError")
      expect(hash[:status]).to eq(500)
    end
  end

  describe Supabase::Auth::Errors::AuthUnknownError do
    it "inherits from AuthError" do
      expect(described_class).to be < Supabase::Auth::Errors::AuthError
    end

    it "wraps an original error" do
      original = RuntimeError.new("boom")
      error = described_class.new("Unexpected error", original_error: original)
      expect(error.message).to eq("Unexpected error")
      expect(error.original_error).to eq(original)
      expect(error.status).to be_nil
      expect(error.code).to be_nil
    end
  end

  it "all error classes can be rescued as AuthError" do
    error_classes = [
      Supabase::Auth::Errors::AuthApiError,
      Supabase::Auth::Errors::AuthInvalidJwtError,
      Supabase::Auth::Errors::AuthSessionMissing,
      Supabase::Auth::Errors::AuthWeakPassword,
      Supabase::Auth::Errors::AuthPKCEError,
      Supabase::Auth::Errors::AuthUnknownError,
      Supabase::Auth::Errors::AuthRetryableError,
      Supabase::Auth::Errors::AuthInvalidCredentialsError,
      Supabase::Auth::Errors::AuthImplicitGrantRedirectError
    ]

    error_classes.each do |klass|
      expect(klass).to be < Supabase::Auth::Errors::AuthError
    end
  end

  describe "aliases" do
    it "AuthSessionMissingError is an alias for AuthSessionMissing" do
      expect(Supabase::Auth::Errors::AuthSessionMissingError).to eq(Supabase::Auth::Errors::AuthSessionMissing)
    end

    it "AuthWeakPasswordError is an alias for AuthWeakPassword" do
      expect(Supabase::Auth::Errors::AuthWeakPasswordError).to eq(Supabase::Auth::Errors::AuthWeakPassword)
    end
  end

  describe "ERROR_CODES" do
    # All 69 error codes from Python's ErrorCode Literal type must be present
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

    it "contains all 81 error codes from Python's ErrorCode type" do
      expect(Supabase::Auth::Errors::ERROR_CODES.length).to eq(81)
    end

    it "matches Python's ErrorCode values exactly" do
      python_error_codes.each do |code|
        expect(Supabase::Auth::Errors::ERROR_CODES).to include(code),
          "Missing error code: #{code}"
      end
    end

    it "has no extra codes beyond Python's set" do
      extra = Supabase::Auth::Errors::ERROR_CODES - python_error_codes
      expect(extra).to be_empty, "Extra error codes not in Python: #{extra.join(', ')}"
    end

    it "is frozen" do
      expect(Supabase::Auth::Errors::ERROR_CODES).to be_frozen
    end
  end
end
