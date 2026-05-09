# frozen_string_literal: true

module Supabase
  module Auth
    module Errors
      # Base error class for all Supabase Auth errors.
      class AuthError < StandardError
        attr_reader :status, :code

        def initialize(message, status: nil, code: nil)
          super(message)
          @status = status
          @code = code
        end

        def to_h
          { message: message, status: @status, code: @code }
        end
      end

      # Raised for GoTrue server API errors (4xx/5xx responses).
      class AuthApiError < AuthError
        def initialize(message, status:, code: nil)
          super(message, status: status, code: code)
        end
      end

      # Raised for unexpected or unrecognized errors.
      class AuthUnknownError < AuthError
        attr_reader :original_error

        def initialize(message, original_error: nil)
          super(message, status: nil, code: nil)
          @original_error = original_error
        end
      end

      # Intermediate class for custom auth errors with name and status.
      class CustomAuthError < AuthError
        attr_reader :name

        def initialize(message, name:, status:, code: nil)
          super(message, status: status, code: code)
          @name = name
        end

        def to_h
          { name: @name, message: message, status: @status, code: @code }
        end
      end

      # Raised when an auth session is required but not present.
      class AuthSessionMissing < CustomAuthError
        def initialize(message = "Auth session missing!")
          super(message, name: "AuthSessionMissingError", status: 400)
        end
      end

      # Raised when credentials are missing or invalid.
      class AuthInvalidCredentialsError < CustomAuthError
        def initialize(message)
          super(message, name: "AuthInvalidCredentialsError", status: 400)
        end
      end

      # Raised when an implicit grant redirect contains an error.
      class AuthImplicitGrantRedirectError < CustomAuthError
        attr_reader :details

        def initialize(message, details: nil)
          super(message, name: "AuthImplicitGrantRedirectError", status: 500)
          @details = details
        end

        def to_h
          { name: @name, message: message, status: @status, code: @code, details: @details }
        end
      end

      # Raised for retryable errors (network issues, 502/503/504).
      class AuthRetryableError < CustomAuthError
        def initialize(message, status: 0)
          super(message, name: "AuthRetryableError", status: status)
        end
      end

      # Raised when a password does not meet strength requirements.
      class AuthWeakPassword < CustomAuthError
        attr_reader :reasons

        def initialize(message, status: 422, reasons: [])
          super(message, name: "AuthWeakPasswordError", status: status, code: "weak_password")
          @reasons = reasons
        end

        def to_h
          { name: @name, message: message, status: @status, code: @code, reasons: @reasons }
        end
      end

      # Raised when a JWT is invalid or malformed.
      class AuthInvalidJwtError < CustomAuthError
        def initialize(message)
          super(message, name: "AuthInvalidJwtError", status: 400, code: "invalid_jwt")
        end
      end

      # Raised for PKCE flow errors.
      class AuthPKCEError < AuthError
        def initialize(message)
          super(message, status: 400, code: "pkce_error")
        end
      end

      # Alias for AuthSessionMissing (matches Python's AuthSessionMissingError)
      AuthSessionMissingError = AuthSessionMissing
      # Alias for AuthWeakPassword (matches Python's AuthWeakPasswordError)
      AuthWeakPasswordError = AuthWeakPassword

      # All known GoTrue error codes.
      ERROR_CODES = %w[
        unexpected_failure
        validation_failed
        bad_json
        email_exists
        phone_exists
        bad_jwt
        not_admin
        no_authorization
        user_not_found
        session_not_found
        flow_state_not_found
        flow_state_expired
        signup_disabled
        user_banned
        provider_email_needs_verification
        invite_not_found
        bad_oauth_state
        bad_oauth_callback
        oauth_provider_not_supported
        unexpected_audience
        single_identity_not_deletable
        email_conflict_identity_not_deletable
        identity_already_exists
        email_provider_disabled
        phone_provider_disabled
        too_many_enrolled_mfa_factors
        mfa_factor_name_conflict
        mfa_factor_not_found
        mfa_ip_address_mismatch
        mfa_challenge_expired
        mfa_verification_failed
        mfa_verification_rejected
        insufficient_aal
        captcha_failed
        saml_provider_disabled
        manual_linking_disabled
        sms_send_failed
        email_not_confirmed
        phone_not_confirmed
        reauth_nonce_missing
        saml_relay_state_not_found
        saml_relay_state_expired
        saml_idp_not_found
        saml_assertion_no_user_id
        saml_assertion_no_email
        user_already_exists
        sso_provider_not_found
        saml_metadata_fetch_failed
        saml_idp_already_exists
        sso_domain_already_exists
        saml_entity_id_mismatch
        conflict
        provider_disabled
        user_sso_managed
        reauthentication_needed
        same_password
        reauthentication_not_valid
        otp_expired
        otp_disabled
        identity_not_found
        weak_password
        over_request_rate_limit
        over_email_send_rate_limit
        over_sms_send_rate_limit
        bad_code_verifier
        anonymous_provider_disabled
        hook_timeout
        hook_timeout_after_retry
        hook_payload_over_size_limit
        hook_payload_invalid_content_type
        request_timeout
        mfa_phone_enroll_not_enabled
        mfa_phone_verify_not_enabled
        mfa_totp_enroll_not_enabled
        mfa_totp_verify_not_enabled
        mfa_webauthn_enroll_not_enabled
        mfa_webauthn_verify_not_enabled
        mfa_verified_factor_exists
        invalid_credentials
        email_address_not_authorized
        email_address_invalid
      ].freeze
    end
  end
end
