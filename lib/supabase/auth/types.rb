# frozen_string_literal: true

require "time"

module Supabase
  module Auth
    module Types
      # Parse an ISO8601 string into a Time object, or return nil
      # @param value [String, Time, nil]
      # @return [Time, nil]
      def self.parse_timestamp(value)
        return nil if value.nil?
        return value if value.is_a?(Time)

        Time.parse(value.to_s)
      end

      Factor = Struct.new(
        :id,
        :friendly_name,
        :factor_type,
        :status,
        :created_at,
        :updated_at,
        keyword_init: true
      ) do
        def self.from_hash(hash)
          return nil if hash.nil?

          new(
            id: hash["id"] || hash[:id],
            friendly_name: hash["friendly_name"] || hash[:friendly_name],
            factor_type: hash["factor_type"] || hash[:factor_type],
            status: hash["status"] || hash[:status],
            created_at: Types.parse_timestamp(hash["created_at"] || hash[:created_at]),
            updated_at: Types.parse_timestamp(hash["updated_at"] || hash[:updated_at])
          )
        end
      end

      Identity = Struct.new(
        :id,
        :user_id,
        :identity_data,
        :provider,
        :last_sign_in_at,
        :created_at,
        :updated_at,
        keyword_init: true
      ) do
        def self.from_hash(hash)
          return nil if hash.nil?

          new(
            id: hash["id"] || hash[:id],
            user_id: hash["user_id"] || hash[:user_id],
            identity_data: hash["identity_data"] || hash[:identity_data] || {},
            provider: hash["provider"] || hash[:provider],
            last_sign_in_at: Types.parse_timestamp(hash["last_sign_in_at"] || hash[:last_sign_in_at]),
            created_at: Types.parse_timestamp(hash["created_at"] || hash[:created_at]),
            updated_at: Types.parse_timestamp(hash["updated_at"] || hash[:updated_at])
          )
        end
      end

      User = Struct.new(
        :id,
        :aud,
        :role,
        :email,
        :email_confirmed_at,
        :phone,
        :phone_confirmed_at,
        :confirmed_at,
        :last_sign_in_at,
        :app_metadata,
        :user_metadata,
        :identities,
        :factors,
        :created_at,
        :updated_at,
        keyword_init: true
      ) do
        def self.from_hash(hash)
          return nil if hash.nil?

          identities = (hash["identities"] || hash[:identities])&.map { |i| Identity.from_hash(i) }
          factors = (hash["factors"] || hash[:factors])&.map { |f| Factor.from_hash(f) }

          new(
            id: hash["id"] || hash[:id],
            aud: hash["aud"] || hash[:aud],
            role: hash["role"] || hash[:role],
            email: hash["email"] || hash[:email],
            email_confirmed_at: Types.parse_timestamp(hash["email_confirmed_at"] || hash[:email_confirmed_at]),
            phone: hash["phone"] || hash[:phone],
            phone_confirmed_at: Types.parse_timestamp(hash["phone_confirmed_at"] || hash[:phone_confirmed_at]),
            confirmed_at: Types.parse_timestamp(hash["confirmed_at"] || hash[:confirmed_at]),
            last_sign_in_at: Types.parse_timestamp(hash["last_sign_in_at"] || hash[:last_sign_in_at]),
            app_metadata: hash["app_metadata"] || hash[:app_metadata] || {},
            user_metadata: hash["user_metadata"] || hash[:user_metadata] || {},
            identities: identities,
            factors: factors,
            created_at: Types.parse_timestamp(hash["created_at"] || hash[:created_at]),
            updated_at: Types.parse_timestamp(hash["updated_at"] || hash[:updated_at])
          )
        end
      end

      Session = Struct.new(
        :access_token,
        :refresh_token,
        :token_type,
        :expires_in,
        :expires_at,
        :user,
        keyword_init: true
      ) do
        def self.from_hash(hash)
          return nil if hash.nil?

          expires_at = hash["expires_at"] || hash[:expires_at]
          expires_at = expires_at ? Time.at(expires_at) : nil

          new(
            access_token: hash["access_token"] || hash[:access_token],
            refresh_token: hash["refresh_token"] || hash[:refresh_token],
            token_type: hash["token_type"] || hash[:token_type],
            expires_in: hash["expires_in"] || hash[:expires_in],
            expires_at: expires_at,
            user: User.from_hash(hash["user"] || hash[:user])
          )
        end
      end

      AuthResponse = Struct.new(
        :user,
        :session,
        keyword_init: true
      ) do
        def self.from_hash(hash)
          return nil if hash.nil?

          new(
            user: User.from_hash(hash["user"] || hash[:user]),
            session: Session.from_hash(hash["session"] || hash[:session])
          )
        end
      end

      OAuthResponse = Struct.new(
        :provider,
        :url,
        keyword_init: true
      )

      GenerateLinkProperties = Struct.new(
        :action_link,
        :email_otp,
        :hashed_token,
        :redirect_to,
        :verification_type,
        keyword_init: true
      )

      GenerateLinkResponse = Struct.new(
        :properties,
        :user,
        keyword_init: true
      )

      UserResponse = Struct.new(
        :user,
        keyword_init: true
      ) do
        def self.from_hash(hash)
          return nil if hash.nil?

          new(user: User.from_hash(hash["user"] || hash[:user]))
        end
      end

      SSOResponse = Struct.new(
        :url,
        keyword_init: true
      ) do
        def self.from_hash(hash)
          return nil if hash.nil?

          new(url: hash["url"] || hash[:url])
        end
      end

      LinkIdentityResponse = Struct.new(
        :url,
        keyword_init: true
      ) do
        def self.from_hash(hash)
          return nil if hash.nil?

          new(url: hash["url"] || hash[:url])
        end
      end

      AuthOtpResponse = Struct.new(
        :message_id,
        :user,
        :session,
        keyword_init: true
      ) do
        def self.from_hash(hash)
          return nil if hash.nil?

          new(
            message_id: hash["message_id"] || hash[:message_id],
            user: hash.key?("user") || hash.key?(:user) ? User.from_hash(hash["user"] || hash[:user]) : nil,
            session: hash.key?("session") || hash.key?(:session) ? Session.from_hash(hash["session"] || hash[:session]) : nil
          )
        end
      end
      # MFA Enroll response - returned when enrolling a new TOTP factor
      AuthMFAEnrollResponse = Struct.new(
        :id,
        :type,
        :friendly_name,
        :totp,
        keyword_init: true
      ) do
        def self.from_hash(hash)
          return nil if hash.nil?

          totp = hash["totp"] || hash[:totp]
          totp_struct = totp ? MFATotpInfo.new(qr_code: totp["qr_code"] || totp[:qr_code],
                                                secret: totp["secret"] || totp[:secret],
                                                uri: totp["uri"] || totp[:uri]) : nil
          new(
            id: hash["id"] || hash[:id],
            type: hash["type"] || hash[:type],
            friendly_name: hash["friendly_name"] || hash[:friendly_name],
            totp: totp_struct
          )
        end
      end

      MFATotpInfo = Struct.new(:qr_code, :secret, :uri, keyword_init: true)

      # MFA Challenge response
      AuthMFAChallengeResponse = Struct.new(
        :id,
        :expires_at,
        keyword_init: true
      ) do
        def self.from_hash(hash)
          return nil if hash.nil?

          new(
            id: hash["id"] || hash[:id],
            expires_at: hash["expires_at"] || hash[:expires_at]
          )
        end
      end

      # MFA Unenroll response
      AuthMFAUnenrollResponse = Struct.new(
        :id,
        keyword_init: true
      ) do
        def self.from_hash(hash)
          return nil if hash.nil?

          new(id: hash["id"] || hash[:id])
        end
      end

      # MFA List Factors response
      AuthMFAListFactorsResponse = Struct.new(
        :all,
        :totp,
        :phone,
        keyword_init: true
      )

      # MFA Verify response
      AuthMFAVerifyResponse = Struct.new(
        :access_token,
        :refresh_token,
        :token_type,
        :expires_in,
        :expires_at,
        :user,
        keyword_init: true
      ) do
        def self.from_hash(hash)
          return nil if hash.nil?

          Session.from_hash(hash)
        end
      end

      # MFA Get Authenticator Assurance Level response
      AuthMFAGetAuthenticatorAssuranceLevelResponse = Struct.new(
        :current_level,
        :next_level,
        :current_authentication_methods,
        keyword_init: true
      )

      # Identities response (wraps user identities)
      IdentitiesResponse = Struct.new(
        :identities,
        keyword_init: true
      )

      # User Identity (includes identity_id)
      UserIdentity = Struct.new(
        :id,
        :identity_id,
        :user_id,
        :identity_data,
        :provider,
        :created_at,
        :last_sign_in_at,
        :updated_at,
        keyword_init: true
      ) do
        def self.from_hash(hash)
          return nil if hash.nil?

          new(
            id: hash["id"] || hash[:id],
            identity_id: hash["identity_id"] || hash[:identity_id],
            user_id: hash["user_id"] || hash[:user_id],
            identity_data: hash["identity_data"] || hash[:identity_data] || {},
            provider: hash["provider"] || hash[:provider],
            created_at: Types.parse_timestamp(hash["created_at"] || hash[:created_at]),
            last_sign_in_at: Types.parse_timestamp(hash["last_sign_in_at"] || hash[:last_sign_in_at]),
            updated_at: Types.parse_timestamp(hash["updated_at"] || hash[:updated_at])
          )
        end
      end
    end
  end
end
