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
      end

      # Raised for GoTrue server API errors (4xx/5xx responses).
      class AuthApiError < AuthError
        def initialize(message, status:, code: nil)
          super(message, status: status, code: code)
        end
      end

      # Raised when a JWT is invalid or malformed.
      class AuthInvalidJwtError < AuthError
        def initialize(message)
          super(message, status: 400, code: "invalid_jwt")
        end
      end

      # Raised when an auth session is required but not present.
      class AuthSessionMissing < AuthError
        def initialize(message = "Auth session missing!")
          super(message, status: 400)
        end
      end

      # Raised when a password does not meet strength requirements.
      class AuthWeakPassword < AuthError
        attr_reader :reasons

        def initialize(message, status: 422, reasons: [])
          super(message, status: status, code: "weak_password")
          @reasons = reasons
        end
      end

      # Raised for PKCE flow errors.
      class AuthPKCEError < AuthError
        def initialize(message)
          super(message, status: 400, code: "pkce_error")
        end
      end

      # Raised for retryable errors (network issues, 502/503/504).
      class AuthRetryableError < AuthError
        def initialize(message, status: 0)
          super(message, status: status)
        end
      end

      # Raised when credentials are missing or invalid.
      class AuthInvalidCredentialsError < AuthError
        def initialize(message)
          super(message, status: 400, code: "invalid_credentials")
        end
      end

      # Raised when an implicit grant redirect contains an error.
      class AuthImplicitGrantRedirectError < AuthError
        def initialize(message, status: 500, code: nil)
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
      # Alias for AuthSessionMissing (matches Python's AuthSessionMissingError)
      AuthSessionMissingError = AuthSessionMissing
    end
  end
end
