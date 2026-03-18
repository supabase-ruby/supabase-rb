# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "securerandom"
require "date"
require "uri"

module Supabase
  module Auth
    module Helpers
      API_VERSION_HEADER_NAME = "X-Supabase-Api-Version"
      API_VERSION_REGEX = /\A2[0-9]{3}-(0[1-9]|1[0-2])-(0[1-9]|1[0-9]|2[0-9]|3[0-1])\z/
      BASE64URL_REGEX = /\A([a-z0-9_-]{4})*($|[a-z0-9_-]{3}$|[a-z0-9_-]{2}$)\z/i
      PKCE_CHARSET = (("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a + %w[- . _ ~]).freeze
      API_VERSION_2024_01_01_TIMESTAMP = Time.new(2024, 1, 1).to_f

      module_function

      def decode_jwt(token)
        parts = token.split(".")
        raise Errors::AuthInvalidJwtError, "Invalid JWT structure" unless parts.length == 3

        parts.each do |part|
          raise Errors::AuthInvalidJwtError, "JWT not in base64url format" unless part.match?(BASE64URL_REGEX)
        end

        header = JSON.parse(str_from_base64url(parts[0]))
        payload = JSON.parse(str_from_base64url(parts[1]))
        signature = base64url_to_bytes(parts[2])

        {
          header: header,
          payload: payload,
          signature: signature,
          raw: { "header" => parts[0], "payload" => parts[1] }
        }
      end

      def str_from_base64url(base64url)
        padded = base64url + "=" * (-base64url.length % 4)
        Base64.urlsafe_decode64(padded)
      end

      def base64url_to_bytes(base64url)
        padded = base64url + "=" * (-base64url.length % 4)
        Base64.urlsafe_decode64(padded)
      end

      def generate_pkce_verifier(length = 64)
        raise ArgumentError, "PKCE verifier length must be between 43 and 128 characters" if length < 43 || length > 128

        Array.new(length) { PKCE_CHARSET.sample(random: SecureRandom) }.join
      end

      def generate_pkce_challenge(code_verifier)
        digest = Digest::SHA256.digest(code_verifier)
        Base64.urlsafe_encode64(digest, padding: false)
      end

      def parse_response_api_version(response)
        headers = response.respond_to?(:headers) ? response.headers : {}
        api_version = headers[API_VERSION_HEADER_NAME]
        return nil if api_version.nil? || api_version.empty?
        return nil unless api_version.match?(API_VERSION_REGEX)

        Date.strptime(api_version, "%Y-%m-%d").to_time
      rescue ArgumentError, TypeError, Date::Error
        nil
      end

      def get_error_code(error)
        return nil unless error.is_a?(Hash)

        error["error_code"] || error[:error_code]
      end

      def is_http_url(url)
        return false if url.nil? || url.empty?

        uri = URI.parse(url)
        %w[http https].include?(uri.scheme)
      rescue URI::InvalidURIError
        false
      end

      def is_valid_uuid(value)
        return false unless value.is_a?(String)

        /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i.match?(value)
      end

      def validate_exp(exp)
        raise Errors::AuthInvalidJwtError, "JWT has no expiration time" if exp.nil? || exp == 0

        raise Errors::AuthInvalidJwtError, "JWT has expired" if exp <= Time.now.to_f
      end

      def handle_exception(exception)
        unless exception.is_a?(Faraday::ClientError) || exception.is_a?(Faraday::ServerError)
          return Errors::AuthRetryableError.new(exception.message, status: 0)
        end

        begin
          response = exception.response
          status = response[:status]

          if [502, 503, 504].include?(status)
            return Errors::AuthRetryableError.new(exception.message, status: status)
          end

          data = JSON.parse(response[:body] || "{}")
          error_code = nil
          response_api_version = nil

          if response[:headers]
            mock_response = Struct.new(:headers).new(response[:headers])
            response_api_version = parse_response_api_version(mock_response)
          end

          if response_api_version &&
             response_api_version.to_f >= API_VERSION_2024_01_01_TIMESTAMP &&
             data.is_a?(Hash) && !data.empty? && data["code"].is_a?(String)
            error_code = data["code"]
          elsif data.is_a?(Hash) && !data.empty? && data["error_code"].is_a?(String)
            error_code = data["error_code"]
          end

          if error_code == "weak_password"
            reasons = data.dig("weak_password", "reasons") || []
            return Errors::AuthWeakPassword.new(
              get_error_message(data),
              status: status,
              reasons: reasons
            )
          end

          if error_code.nil? && data.is_a?(Hash) && data["weak_password"].is_a?(Hash) && !data["weak_password"].empty?
            reasons = data["weak_password"]["reasons"] || []
            return Errors::AuthWeakPassword.new(
              get_error_message(data),
              status: status,
              reasons: reasons
            )
          end

          Errors::AuthApiError.new(
            get_error_message(data),
            status: status || 500,
            code: error_code
          )
        rescue StandardError => e
          Errors::AuthUnknownError.new(exception.message, original_error: e)
        end
      end

      def get_error_message(error)
        props = %w[msg message error_description error]
        if error.is_a?(Hash)
          props.each { |prop| return error[prop] if error.key?(prop) }
        else
          props.each { |prop| return error.send(prop) if error.respond_to?(prop) }
        end
        error.to_s
      end

      def parse_auth_response(data)
        session = nil
        if data["access_token"] && data["refresh_token"] && data["expires_in"]
          session = Types::Session.from_hash(data)
        end
        user_data = data["user"] || data
        user = user_data ? Types::User.from_hash(user_data) : nil
        Types::AuthResponse.new(session: session, user: user)
      end

      def parse_auth_otp_response(data)
        Types::AuthOtpResponse.from_hash(data)
      end

      def parse_link_identity_response(data)
        Types::LinkIdentityResponse.from_hash(data)
      end

      def parse_link_response(data)
        link_keys = Types::GenerateLinkProperties.members.map(&:to_s)
        props_hash = link_keys.each_with_object({}) { |k, h| h[k.to_sym] = data[k] }
        properties = Types::GenerateLinkProperties.new(**props_hash)
        user_data = data.reject { |k, _| link_keys.include?(k) }
        user = Types::User.from_hash(user_data)
        Types::GenerateLinkResponse.new(properties: properties, user: user)
      end

      def parse_user_response(data)
        data = { "user" => data } unless data.key?("user")
        Types::UserResponse.from_hash(data)
      end

      def parse_sso_response(data)
        Types::SSOResponse.from_hash(data)
      end

      def parse_jwks(response)
        if !response.key?("keys") || response["keys"].empty?
          raise Errors::AuthInvalidJwtError, "JWKS is empty"
        end

        { "keys" => response["keys"] }
      end

      def parse_error_body(body)
        return {} if body.nil? || body.empty?

        JSON.parse(body)
      rescue JSON::ParserError
        {}
      end

      private_class_method :str_from_base64url, :base64url_to_bytes, :get_error_message, :parse_error_body
    end
  end
end
