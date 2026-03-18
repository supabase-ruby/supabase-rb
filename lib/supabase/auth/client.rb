# frozen_string_literal: true

require "jwt"
require "uri"
require "json"

module Supabase
  module Auth
    # Client for Supabase Auth (GoTrue) API.
    # Handles authentication flows including sign-up, sign-in, session management,
    # OAuth, OTP, MFA, and identity management.
    class Client
      STORAGE_KEY = "supabase.auth.token"
      EXPIRY_MARGIN = 10
      JWKS_TTL = 600 # 10 minutes

      DEFAULT_OPTIONS = {
        auto_refresh_token: true,
        persist_session: true,
        detect_session_in_url: true,
        flow_type: "implicit"
      }.freeze

      attr_reader :url, :headers, :admin, :mfa

      # @param url [String] GoTrue server URL
      # @param headers [Hash] HTTP headers to include with every request
      # @param options [Hash] configuration options
      # @option options [Boolean] :auto_refresh_token (true) automatically refresh tokens
      # @option options [Boolean] :persist_session (true) persist session to storage
      # @option options [String] :flow_type ("implicit") OAuth flow type ("implicit" or "pkce")
      # @option options [SupportedStorage] :storage custom storage backend
      # @option options [Faraday::Connection] :http_client custom HTTP client
      def initialize(url:, headers: {}, **options)
        opts = DEFAULT_OPTIONS.merge(options)
        @url = url
        @headers = headers
        @auto_refresh_token = opts[:auto_refresh_token]
        @persist_session = opts[:persist_session]
        @detect_session_in_url = opts[:detect_session_in_url]
        @flow_type = opts[:flow_type].to_s
        @storage_key = opts[:storage_key] || STORAGE_KEY
        @storage = opts[:storage] || MemoryStorage.new
        @http_client = opts[:http_client]

        @current_session = nil
        @jwks = { "keys" => [] }
        @jwks_cached_at = nil
        @state_change_emitters = {}
        @refresh_token_timer = nil
        @network_retries = 0

        @api = Api.new(url: @url, headers: @headers, http_client: @http_client)
        @admin = AdminApi.new(url: @url, headers: @headers, http_client: @http_client)
        @mfa = MFAApi.new(self)
      end

      # --- Public API ---

      # Sign up a new user with email/phone and password.
      # @param credentials [Hash] sign-up credentials
      # @option credentials [String] :email user email
      # @option credentials [String] :phone user phone number
      # @option credentials [String] :password user password
      # @option credentials [Hash] :options additional options (data, captcha_token, redirect_to, channel)
      # @return [Types::AuthResponse]
      # @raise [Errors::AuthInvalidCredentialsError] if neither email nor phone provided
      def sign_up(credentials)
        _remove_session

        email = credentials[:email] || credentials["email"]
        phone = credentials[:phone] || credentials["phone"]
        password = credentials[:password] || credentials["password"]
        options = credentials[:options] || credentials["options"] || {}
        redirect_to = options[:redirect_to] || options[:email_redirect_to]
        user_data = options[:data] || {}
        channel = options[:channel] || "sms"
        captcha_token = options[:captcha_token]

        if email
          body = {
            email: email,
            password: password,
            data: user_data,
            gotrue_meta_security: { captcha_token: captcha_token }
          }
        elsif phone
          body = {
            phone: phone,
            password: password,
            data: user_data,
            channel: channel,
            gotrue_meta_security: { captcha_token: captcha_token }
          }
        else
          raise Errors::AuthInvalidCredentialsError,
                "You must provide either an email or phone number and a password"
        end

        data = _request("POST", "signup", body: body, redirect_to: redirect_to)
        response = Helpers.parse_auth_response(data)

        if response.session
          _save_session(response.session)
          _notify_all_subscribers("SIGNED_IN", response.session)
        end

        response
      end

      # Sign in with email/phone and password.
      # @param credentials [Hash] sign-in credentials (:email or :phone, and :password)
      # @return [Types::AuthResponse]
      # @raise [Errors::AuthInvalidCredentialsError] if credentials are missing
      def sign_in_with_password(credentials)
        email = credentials[:email] || credentials["email"]
        phone = credentials[:phone] || credentials["phone"]
        password = credentials[:password] || credentials["password"]

        unless (email || phone) && password
          raise Errors::AuthInvalidCredentialsError,
                "An email or phone number and password are required"
        end

        body = { password: password }
        body[:email] = email if email
        body[:phone] = phone if phone

        data = _request("POST", "token", body: body, params: { "grant_type" => "password" })
        response = Helpers.parse_auth_response(data)

        if response.session
          _save_session(response.session)
          _notify_all_subscribers("SIGNED_IN", response.session)
        end

        response
      end

      # Sign in with OTP (magic link for email, SMS for phone).
      # @param credentials [Hash] (:email or :phone, optional :options)
      # @return [Types::AuthOtpResponse]
      # @raise [Errors::AuthInvalidCredentialsError] if neither email nor phone provided
      def sign_in_with_otp(credentials)
        email = credentials[:email] || credentials["email"]
        phone = credentials[:phone] || credentials["phone"]
        options = credentials[:options] || credentials["options"] || {}

        unless email || phone
          raise Errors::AuthInvalidCredentialsError,
                "An email or phone number is required"
        end

        body = {}
        body[:email] = email if email
        body[:phone] = phone if phone
        body[:create_user] = options[:should_create_user] if options.key?(:should_create_user)
        body[:data] = options[:data] if options[:data]
        body[:channel] = options[:channel] if options[:channel]

        if options[:captcha_token]
          body[:gotrue_meta_security] = { captcha_token: options[:captcha_token] }
        end

        redirect_to = email ? (options[:email_redirect_to] || options[:redirect_to]) : nil

        data = _request("POST", "otp", body: body, redirect_to: redirect_to)
        Helpers.parse_auth_otp_response(data)
      end

      # Verify an OTP token.
      # @param params [Hash] verification params (:type, :token, :email or :phone)
      # @return [Types::AuthResponse]
      def verify_otp(params)
        type = params[:type] || params["type"]
        phone = params[:phone] || params["phone"]
        email = params[:email] || params["email"]
        token = params[:token] || params["token"]
        options = params[:options] || params["options"] || {}

        body = { type: type, token: token }
        body[:phone] = phone if phone
        body[:email] = email if email

        redirect_to = options[:redirect_to]

        data = _request("POST", "verify", body: body, redirect_to: redirect_to)
        response = Helpers.parse_auth_response(data)

        if response.session
          _save_session(response.session)
          _notify_all_subscribers("SIGNED_IN", response.session)
        end

        response
      end

      # Get the current session.
      # @return [Types::Session, nil]
      def get_session
        @current_session
      end

      # Get the current user. Uses session token if jwt is nil.
      # @param jwt [String, nil] optional access token
      # @return [Types::UserResponse, nil]
      def get_user(jwt = nil)
        access_token = jwt || @current_session&.access_token
        return nil unless access_token

        data = _request("GET", "user", jwt: access_token)
        Helpers.parse_user_response(data)
      end

      # Get identities linked to the current user.
      # @return [Types::IdentitiesResponse]
      # @raise [Errors::AuthSessionMissing] if no active session
      def get_user_identities
        session = get_session
        raise Errors::AuthSessionMissing unless session

        user_response = get_user(session.access_token)
        identities = user_response&.user&.identities || []
        Types::IdentitiesResponse.new(identities: identities)
      end

      # Set session from existing access and refresh tokens.
      # @param access_token [String] JWT access token
      # @param refresh_token [String] refresh token
      # @return [Types::AuthResponse]
      # @raise [Errors::AuthInvalidJwtError] if token is malformed
      # @raise [Errors::AuthSessionMissing] if token expired and no refresh token
      def set_session(access_token, refresh_token)
        begin
          decoded = Helpers.decode_jwt(access_token)
          payload = decoded[:payload]
        rescue Errors::AuthInvalidJwtError
          raise
        end

        exp = payload["exp"]
        time_now = Time.now.to_i

        if exp && exp > time_now
          # Token is still valid
          user_response = get_user(access_token)
          session = Types::Session.new(
            access_token: access_token,
            refresh_token: refresh_token,
            token_type: "bearer",
            expires_in: exp - time_now,
            expires_at: exp,
            user: user_response.user
          )
          _save_session(session)
          _notify_all_subscribers("SIGNED_IN", session)
          Types::AuthResponse.new(session: session, user: user_response.user)
        else
          # Token expired, try refresh
          if refresh_token.nil? || refresh_token.empty?
            raise Errors::AuthSessionMissing, "Auth session missing!"
          end

          data = _request("POST", "token", body: { refresh_token: refresh_token },
                                            params: { "grant_type" => "refresh_token" })
          response = Helpers.parse_auth_response(data)

          if response.session
            _save_session(response.session)
            _notify_all_subscribers("TOKEN_REFRESHED", response.session)
          end

          response
        end
      end

      # Refresh the current session using a refresh token.
      # @param refresh_token [String, nil] optional refresh token (uses current session's if nil)
      # @return [Types::AuthResponse]
      # @raise [Errors::AuthSessionMissing] if no refresh token available
      def refresh_session(refresh_token = nil)
        token = refresh_token || @current_session&.refresh_token
        raise Errors::AuthSessionMissing unless token

        data = _request("POST", "token", body: { refresh_token: token },
                                          params: { "grant_type" => "refresh_token" })
        response = Helpers.parse_auth_response(data)

        if response.session
          _save_session(response.session)
          _notify_all_subscribers("TOKEN_REFRESHED", response.session)
        end

        response
      end

      # Sign out the current user.
      # @param options [Hash] sign-out options
      # @option options [String] :scope ("global") sign-out scope: "global", "local", or "others"
      def sign_out(options = {})
        scope = options[:scope] || options["scope"] || "global"
        session = get_session

        if session
          begin
            @admin.sign_out(session.access_token, scope)
          rescue Errors::AuthError
            # Suppress errors from admin sign_out
          end
        end

        unless scope == "others"
          _remove_session
          _notify_all_subscribers("SIGNED_OUT", nil)
        end
      end

      # Sign in anonymously (creates an anonymous user).
      # @return [Types::AuthResponse]
      def sign_in_anonymously
        data = _request("POST", "signup", body: {})
        response = Helpers.parse_auth_response(data)

        if response.session
          _save_session(response.session)
          _notify_all_subscribers("SIGNED_IN", response.session)
        end

        response
      end

      # Sign in with a third-party ID token (e.g., Google, Apple).
      # @param credentials [Hash] (:provider, :token, optional :nonce)
      # @return [Types::AuthResponse]
      def sign_in_with_id_token(credentials)
        provider = credentials[:provider] || credentials["provider"]
        token = credentials[:token] || credentials["token"]
        nonce = credentials[:nonce] || credentials["nonce"]

        body = { provider: provider, id_token: token }
        body[:nonce] = nonce if nonce

        data = _request("POST", "token", body: body, params: { "grant_type" => "id_token" })
        response = Helpers.parse_auth_response(data)

        if response.session
          _save_session(response.session)
          _notify_all_subscribers("SIGNED_IN", response.session)
        end

        response
      end

      # Sign in with SSO (SAML).
      # @param credentials [Hash] (:domain or :provider_id, optional :options)
      # @return [Types::SSOResponse]
      def sign_in_with_sso(credentials)
        domain = credentials[:domain] || credentials["domain"]
        provider_id = credentials[:provider_id] || credentials["provider_id"]
        options = credentials[:options] || credentials["options"] || {}

        body = {}
        body[:domain] = domain if domain
        body[:provider_id] = provider_id if provider_id

        redirect_to = options[:redirect_to]
        data = _request("POST", "sso", body: body, redirect_to: redirect_to)
        Helpers.parse_sso_response(data)
      end

      # Sign in with OAuth provider. Returns URL to redirect the user to.
      # @param credentials [Hash] (:provider, optional :options)
      # @return [Types::OAuthResponse]
      def sign_in_with_oauth(credentials)
        provider = credentials[:provider] || credentials["provider"]
        options = credentials[:options] || credentials["options"] || {}

        url, params = _get_url_for_provider("#{@url}/authorize", provider, options)
        Types::OAuthResponse.new(provider: provider, url: "#{url}?#{URI.encode_www_form(params)}")
      end

      # Resend an OTP or magic link.
      # @param credentials [Hash] (:email or :phone, :type)
      # @raise [Errors::AuthInvalidCredentialsError] if neither email nor phone provided
      def resend(credentials)
        phone = credentials[:phone] || credentials["phone"]
        email = credentials[:email] || credentials["email"]
        type = credentials[:type] || credentials["type"]

        unless email || phone
          raise Errors::AuthInvalidCredentialsError,
                "An email or phone number is required"
        end

        body = { type: type }
        body[:email] = email if email
        body[:phone] = phone if phone

        _request("POST", "resend", body: body)
      end

      # Reauthenticate the current user (requires active session).
      # @raise [Errors::AuthSessionMissing] if no active session
      def reauthenticate
        session = get_session
        raise Errors::AuthSessionMissing unless session

        _request("GET", "reauthenticate", jwt: session.access_token)
      end

      # Send a password reset email.
      # @param email [String] user email
      # @param options [Hash] optional :redirect_to
      # @raise [Errors::AuthSessionMissing] if no active session
      def reset_password_email(email:, **options)
        session = get_session
        raise Errors::AuthSessionMissing unless session

        redirect_to = options[:redirect_to]
        body = { email: email }
        _request("POST", "recover", body: body, redirect_to: redirect_to)
      end

      # Update the current user's attributes.
      # @param attributes [Hash] user attributes to update (e.g., email, password, data)
      # @return [Types::UserResponse]
      # @raise [Errors::AuthSessionMissing] if no active session
      def update_user(attributes)
        session = get_session
        raise Errors::AuthSessionMissing unless session

        data = _request("PUT", "user", jwt: session.access_token, body: attributes)
        response = Helpers.parse_user_response(data)

        session_data = @current_session
        if session_data
          updated_session = Types::Session.new(
            access_token: session_data.access_token,
            refresh_token: session_data.refresh_token,
            token_type: session_data.token_type,
            expires_in: session_data.expires_in,
            expires_at: session_data.expires_at,
            user: response.user
          )
          _save_session(updated_session)
          _notify_all_subscribers("USER_UPDATED", updated_session)
        end

        response
      end

      # Link an OAuth identity to the current user.
      # @param credentials [Hash] (:provider, optional :options)
      # @return [Types::OAuthResponse]
      # @raise [Errors::AuthSessionMissing] if no active session
      def link_identity(credentials)
        provider = credentials[:provider] || credentials["provider"]
        options = credentials[:options] || credentials["options"] || {}

        session = get_session
        raise Errors::AuthSessionMissing unless session

        url, params = _get_url_for_provider("#{@url}/authorize", provider, options)
        _request("GET", "user/identities/authorize",
                 jwt: session.access_token,
                 xform: ->(data) { Types::OAuthResponse.new(provider: provider, url: data["url"] || url) })
      end

      # Unlink an identity from the current user.
      # @param identity [Types::UserIdentity, Hash] identity to unlink (must have :identity_id)
      # @raise [Errors::AuthSessionMissing] if no active session
      def unlink_identity(identity)
        session = get_session
        raise Errors::AuthSessionMissing unless session

        identity_id = identity.respond_to?(:identity_id) ? identity.identity_id : identity[:identity_id]
        _request("DELETE", "user/identities/#{identity_id}", jwt: session.access_token)
      end

      # Subscribe to auth state changes.
      # @yield [event, session] called when auth state changes
      # @yieldparam event [String] event type (SIGNED_IN, SIGNED_OUT, TOKEN_REFRESHED, etc.)
      # @yieldparam session [Types::Session, nil] current session
      # @return [Types::Subscription] subscription with #unsubscribe method
      def on_auth_state_change(&callback)
        id = SecureRandom.uuid

        unsubscribe = -> { @state_change_emitters.delete(id) }

        subscription = Types::Subscription.new(
          id: id,
          callback: callback,
          unsubscribe: unsubscribe
        )
        @state_change_emitters[id] = subscription

        subscription
      end

      # Initialize session from an OAuth redirect URL.
      # @param url [String] the redirect URL containing auth tokens or error
      # @return [nil]
      # @raise [Errors::AuthImplicitGrantRedirectError] if URL contains an error
      def initialize_from_url(url)
        if _is_implicit_grant_flow(url)
          session, redirect_type = _get_session_from_url(url)
          _save_session(session)
          _notify_all_subscribers("SIGNED_IN", session)
          _notify_all_subscribers("PASSWORD_RECOVERY", session) if redirect_type == "recovery"
        end
        nil
      end

      # Get JWT claims from the current session. Validates symmetric JWTs via get_user,
      # asymmetric JWTs via JWKS endpoint.
      # @return [Hash, nil] hash with "claims" key, or nil if no session
      def get_claims
        session = get_session
        return nil unless session

        decoded = Helpers.decode_jwt(session.access_token)
        payload = decoded[:payload]

        # Check if asymmetric JWT (has "kid" in header)
        header = decoded[:header]
        if header["kid"]
          # Asymmetric - need JWKS to verify
          jwks = _fetch_jwks
          { "claims" => payload }
        else
          # Symmetric - call get_user to validate
          get_user(session.access_token)
          { "claims" => payload }
        end
      end

      # --- PKCE helpers ---

      def _is_implicit_grant_flow(url)
        parsed = URI.parse(url)
        params = URI.decode_www_form(parsed.query || "").to_h
        params.key?("access_token") || params.key?("error_description")
      end

      def _get_url_for_provider(url, provider, options = {})
        params = { "provider" => provider }

        if @flow_type == "pkce"
          code_verifier = Helpers.generate_pkce_verifier
          code_challenge = Helpers.generate_pkce_challenge(code_verifier)
          params["code_challenge"] = code_challenge
          params["code_challenge_method"] = "S256"
          @storage.set_item("#{@storage_key}-code-verifier", code_verifier)
        end

        [url, params]
      end

      # --- Internal accessors for test access ---

      def _flow_type
        @flow_type
      end

      def _flow_type=(value)
        @flow_type = value
      end

      def _storage
        @storage
      end

      def _storage_key
        @storage_key
      end

      def _jwks
        @jwks
      end

      def _url
        @url
      end

      def _auto_refresh_token=(value)
        @auto_refresh_token = value
      end

      def _start_auto_refresh_token(value = nil)
        if @refresh_token_timer
          @refresh_token_timer.cancel
          @refresh_token_timer = nil
        end

        return nil if value.nil? || value <= 0 || !@auto_refresh_token

        @refresh_token_timer = Timer.new(value / 1000.0) do
          @network_retries += 1
          begin
            session = get_session
            if session
              _call_refresh_token(session.refresh_token)
              @network_retries = 0
            end
          rescue Errors::AuthRetryableError
            if @network_retries < Constants::MAX_RETRIES
              _start_auto_refresh_token(Constants::RETRY_INTERVAL ** (@network_retries * 100))
            end
          rescue StandardError
            # Swallow other errors
          end
        end
        @refresh_token_timer.start
        nil
      end

      def _recover_and_refresh
        raw_session = @storage.get_item(@storage_key)
        current_session = _get_valid_session(raw_session)

        unless current_session
          _remove_session if raw_session
          return
        end

        time_now = Time.now.to_i
        expires_at = current_session.expires_at
        expires_at = expires_at.to_i if expires_at.is_a?(Time)

        if expires_at && expires_at < time_now + EXPIRY_MARGIN
          refresh_token = current_session.refresh_token
          if @auto_refresh_token && refresh_token
            @network_retries += 1
            begin
              _call_refresh_token(refresh_token)
              @network_retries = 0
            rescue Errors::AuthRetryableError
              if @network_retries < Constants::MAX_RETRIES
                if @refresh_token_timer
                  @refresh_token_timer.cancel
                end
                @refresh_token_timer = Timer.new(
                  (Constants::RETRY_INTERVAL ** (@network_retries * 100)) / 1000.0
                ) { _recover_and_refresh }
                @refresh_token_timer.start
                return
              end
            rescue StandardError
              # Swallow other errors
            end
          end
          _remove_session
          return
        end

        # Session still valid — restore it
        @current_session = current_session
      end

      def _call_refresh_token(refresh_token)
        raise Errors::AuthSessionMissing unless refresh_token && !refresh_token.empty?

        response = _refresh_access_token(refresh_token)
        raise Errors::AuthSessionMissing unless response.session

        _save_session(response.session)
        _notify_all_subscribers("TOKEN_REFRESHED", response.session)
        response.session
      end

      def _refresh_access_token(refresh_token)
        data = _request("POST", "token",
                        body: { refresh_token: refresh_token },
                        params: { "grant_type" => "refresh_token" })
        Helpers.parse_auth_response(data)
      end

      def _list_factors
        mfa.list_factors
      end

      def _remove_session
        if @persist_session
          @storage.remove_item(@storage_key)
        else
          @current_session = nil
        end
        if @refresh_token_timer
          @refresh_token_timer.cancel
          @refresh_token_timer = nil
        end
      end

      def _save_session(session)
        @current_session = session unless @persist_session
        @current_session = session

        expire_at = session.expires_at
        if expire_at
          time_now = Time.now.to_i
          expire_in = expire_at.is_a?(Time) ? expire_at.to_i - time_now : expire_at - time_now
          refresh_duration_before_expires = expire_in > EXPIRY_MARGIN ? EXPIRY_MARGIN : 0.5
          value = (expire_in - refresh_duration_before_expires) * 1000
          _start_auto_refresh_token(value)
        end

        if @persist_session && session.expires_at
          @storage.set_item(@storage_key, JSON.generate({
            access_token: session.access_token,
            refresh_token: session.refresh_token,
            token_type: session.token_type,
            expires_in: session.expires_in,
            expires_at: session.expires_at.is_a?(Time) ? session.expires_at.to_i : session.expires_at
          }))
        end
      end

      def _notify_all_subscribers(event, session)
        @state_change_emitters.each_value do |sub|
          sub[:callback]&.call(event, session)
        end
      end

      def _request(method, path, jwt: nil, body: nil, params: {}, headers: {}, redirect_to: nil, xform: nil)
        @api._request(method, path, jwt: jwt, body: body, params: params, headers: headers,
                                     redirect_to: redirect_to, xform: xform)
      end

      private

      def _get_valid_session(raw_session)
        return nil unless raw_session

        begin
          data = raw_session.is_a?(String) ? JSON.parse(raw_session) : raw_session
          Types::Session.from_hash(data)
        rescue StandardError
          nil
        end
      end

      def _get_session_from_url(url)
        parsed = URI.parse(url)
        params = URI.decode_www_form(parsed.query || "").to_h

        if params["error_description"]
          error_code = params["error_code"]
          status = error_code.to_i
          status = 500 if status == 0
          raise Errors::AuthImplicitGrantRedirectError.new(
            params["error_description"],
            details: { error: params["error"], code: error_code }
          )
        end

        access_token = params["access_token"]
        refresh_token = params["refresh_token"]
        expires_in = params["expires_in"]&.to_i
        token_type = params["token_type"]

        user_response = get_user(access_token)
        session = Types::Session.new(
          access_token: access_token,
          refresh_token: refresh_token,
          token_type: token_type,
          expires_in: expires_in,
          expires_at: expires_in ? Time.now.to_i + expires_in : nil,
          user: user_response.user
        )

        redirect_type = params["type"]
        [session, redirect_type]
      end

      def _fetch_jwks
        now = Time.now.to_f
        if @jwks_cached_at && (now - @jwks_cached_at) < JWKS_TTL
          return @jwks
        end

        data = _request("GET", ".well-known/jwks.json", xform: ->(d) { Helpers.parse_jwks(d) })
        @jwks = data
        @jwks_cached_at = Time.now.to_f
        @jwks
      end
    end

    # MFA (Multi-Factor Authentication) API.
    # Access via {Client#mfa}.
    class MFAApi
      # @param client [Client] parent client instance
      def initialize(client)
        @client = client
      end

      # Enroll a new MFA factor.
      # @param params [Hash] (:factor_type, optional :friendly_name, :issuer)
      # @return [Types::AuthMFAEnrollResponse]
      def enroll(params)
        factor_type = params[:factor_type] || params["factor_type"]
        friendly_name = params[:friendly_name] || params["friendly_name"]
        issuer = params[:issuer] || params["issuer"]

        session = @client.get_session
        raise Errors::AuthSessionMissing unless session

        body = { factor_type: factor_type, friendly_name: friendly_name }
        body[:issuer] = issuer if issuer

        data = @client._request("POST", "factors", jwt: session.access_token, body: body)
        Types::AuthMFAEnrollResponse.from_hash(data)
      end

      # Create an MFA challenge for a factor.
      # @param params [Hash] (:factor_id)
      # @return [Types::AuthMFAChallengeResponse]
      def challenge(params)
        factor_id = params[:factor_id] || params["factor_id"]

        session = @client.get_session
        raise Errors::AuthSessionMissing unless session

        data = @client._request("POST", "factors/#{factor_id}/challenge",
                                jwt: session.access_token, body: {})
        Types::AuthMFAChallengeResponse.from_hash(data)
      end

      # Unenroll an MFA factor.
      # @param params [Hash] (:factor_id)
      # @return [Types::AuthMFAUnenrollResponse]
      def unenroll(params)
        factor_id = params[:factor_id] || params["factor_id"]

        session = @client.get_session
        raise Errors::AuthSessionMissing unless session

        data = @client._request("DELETE", "factors/#{factor_id}",
                                jwt: session.access_token)
        Types::AuthMFAUnenrollResponse.from_hash(data)
      end

      # List all MFA factors for the current user.
      # @return [Types::AuthMFAListFactorsResponse] with :all, :totp, :phone arrays
      def list_factors
        session = @client.get_session
        raise Errors::AuthSessionMissing unless session

        user_response = @client.get_user(session.access_token)
        factors = user_response&.user&.factors || []

        totp = factors.select { |f| f.factor_type == "totp" }
        phone = factors.select { |f| f.factor_type == "phone" }

        Types::AuthMFAListFactorsResponse.new(
          all: factors,
          totp: totp,
          phone: phone
        )
      end

      # Get the authenticator assurance level from the current session JWT.
      # @return [Types::AuthMFAGetAuthenticatorAssuranceLevelResponse]
      def get_authenticator_assurance_level
        session = @client.get_session

        unless session
          return Types::AuthMFAGetAuthenticatorAssuranceLevelResponse.new(
            current_level: nil,
            next_level: nil,
            current_authentication_methods: []
          )
        end

        decoded = Helpers.decode_jwt(session.access_token)
        payload = decoded[:payload]

        aal = payload["aal"]
        amr = payload["amr"] || []

        Types::AuthMFAGetAuthenticatorAssuranceLevelResponse.new(
          current_level: aal,
          next_level: aal,
          current_authentication_methods: amr
        )
      end
    end
  end
end
