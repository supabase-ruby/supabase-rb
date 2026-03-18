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
      ALG_TO_DIGEST = {
        "RS256" => "SHA256", "RS384" => "SHA384", "RS512" => "SHA512",
        "ES256" => "SHA256", "ES384" => "SHA384", "ES512" => "SHA512",
        "PS256" => "SHA256", "PS384" => "SHA384", "PS512" => "SHA512"
      }.freeze

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

      # Initialize the client, optionally from a URL or from storage.
      # @param url [String, nil] optional redirect URL to initialize from
      def init(url: nil)
        if url && _is_implicit_grant_flow(url)
          initialize_from_url(url)
        else
          initialize_from_storage
        end
      end

      # Recover session from storage and refresh if needed.
      def initialize_from_storage
        _recover_and_refresh
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
        _remove_session

        email = credentials[:email] || credentials["email"]
        phone = credentials[:phone] || credentials["phone"]
        password = credentials[:password] || credentials["password"]
        options = credentials[:options] || credentials["options"] || {}
        data_attr = options[:data] || {}
        captcha_token = options[:captcha_token]

        unless (email || phone) && password
          raise Errors::AuthInvalidCredentialsError,
                "An email or phone number and password are required"
        end

        body = {
          password: password,
          data: data_attr,
          gotrue_meta_security: { captcha_token: captcha_token }
        }
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
        _remove_session

        email = credentials[:email] || credentials["email"]
        phone = credentials[:phone] || credentials["phone"]
        options = credentials[:options] || credentials["options"] || {}

        unless email || phone
          raise Errors::AuthInvalidCredentialsError,
                "An email or phone number is required"
        end

        email_redirect_to = options[:email_redirect_to]
        should_create_user = options.key?(:should_create_user) ? options[:should_create_user] : true
        data_attr = options[:data]
        channel = options[:channel] || "sms"
        captcha_token = options[:captcha_token]

        if email
          body = {
            email: email,
            data: data_attr,
            create_user: should_create_user,
            gotrue_meta_security: { captcha_token: captcha_token }
          }
          data = _request("POST", "otp", body: body, redirect_to: email_redirect_to)
          return Helpers.parse_auth_otp_response(data)
        end

        if phone
          body = {
            phone: phone,
            data: data_attr,
            create_user: should_create_user,
            channel: channel,
            gotrue_meta_security: { captcha_token: captcha_token }
          }
          data = _request("POST", "otp", body: body)
          return Helpers.parse_auth_otp_response(data)
        end
      end

      # Verify an OTP token.
      # @param params [Hash] verification params (:type, :token, :email or :phone)
      # @return [Types::AuthResponse]
      def verify_otp(params)
        _remove_session

        type = params[:type] || params["type"]
        phone = params[:phone] || params["phone"]
        email = params[:email] || params["email"]
        token = params[:token] || params["token"]
        token_hash = params[:token_hash] || params["token_hash"]
        options = params[:options] || params["options"] || {}
        captcha_token = options[:captcha_token]

        body = {
          type: type,
          token: token,
          gotrue_meta_security: { captcha_token: captcha_token }
        }
        body[:phone] = phone if phone
        body[:email] = email if email
        body[:token_hash] = token_hash if token_hash

        redirect_to = options[:redirect_to]

        data = _request("POST", "verify", body: body, redirect_to: redirect_to)
        response = Helpers.parse_auth_response(data)

        if response.session
          _save_session(response.session)
          _notify_all_subscribers("SIGNED_IN", response.session)
        end

        response
      end

      # Get the current session, refreshing it if necessary.
      # @return [Types::Session, nil]
      def get_session
        current_session = nil
        if @persist_session
          maybe_session = @storage.get_item(@storage_key)
          current_session = _get_valid_session(maybe_session)
          _remove_session unless current_session
        else
          current_session = @current_session
        end
        return nil unless current_session

        time_now = Time.now.to_i
        has_expired = current_session.expires_at ? current_session.expires_at <= time_now + EXPIRY_MARGIN : false

        if has_expired
          _call_refresh_token(current_session.refresh_token)
        else
          current_session
        end
      end

      # Get the current user. Uses session token if jwt is nil.
      # @param jwt [String, nil] optional access token
      # @return [Types::UserResponse, nil]
      def get_user(jwt = nil)
        unless jwt
          session = get_session
          return nil unless session
          jwt = session.access_token
        end
        access_token = jwt
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
        time_now = Time.now.to_i
        expires_at = time_now
        has_expired = true
        session = nil

        if access_token && access_token.split(".").length > 1
          payload = Helpers.decode_jwt(access_token)[:payload]
          exp = payload["exp"]
          if exp
            expires_at = exp.to_i
            has_expired = expires_at <= time_now
          end
        end

        if has_expired
          raise Errors::AuthSessionMissing unless refresh_token && !refresh_token.empty?

          response = _refresh_access_token(refresh_token)
          return Types::AuthResponse.new unless response.session

          session = response.session
        else
          user_response = get_user(access_token)
          session = Types::Session.new(
            access_token: access_token,
            refresh_token: refresh_token,
            token_type: "bearer",
            expires_in: expires_at - time_now,
            expires_at: expires_at,
            user: user_response.user
          )
        end

        _save_session(session)
        _notify_all_subscribers("TOKEN_REFRESHED", session)
        Types::AuthResponse.new(session: session, user: session.user)
      end

      # Refresh the current session using a refresh token.
      # @param refresh_token [String, nil] optional refresh token (uses current session's if nil)
      # @return [Types::AuthResponse]
      # @raise [Errors::AuthSessionMissing] if no refresh token available
      def refresh_session(refresh_token = nil)
        unless refresh_token
          session = get_session
          refresh_token = session.refresh_token if session
        end
        raise Errors::AuthSessionMissing unless refresh_token

        session = _call_refresh_token(refresh_token)
        Types::AuthResponse.new(session: session, user: session.user)
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
          rescue Errors::AuthApiError
            # Suppress API errors from admin sign_out
          end
        end

        unless scope == "others"
          _remove_session
          _notify_all_subscribers("SIGNED_OUT", nil)
        end
      end

      # Sign in anonymously (creates an anonymous user).
      # @return [Types::AuthResponse]
      def sign_in_anonymously(credentials = nil)
        _remove_session

        credentials ||= { options: {} }
        options = credentials[:options] || credentials["options"] || {}
        data_attr = options[:data] || {}
        captcha_token = options[:captcha_token]

        data = _request("POST", "signup", body: {
          data: data_attr,
          gotrue_meta_security: { captcha_token: captcha_token }
        })
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
        _remove_session

        provider = credentials[:provider] || credentials["provider"]
        token = credentials[:token] || credentials["token"]
        access_token = credentials[:access_token] || credentials["access_token"]
        nonce = credentials[:nonce] || credentials["nonce"]
        options = credentials[:options] || credentials["options"] || {}
        captcha_token = options[:captcha_token]

        body = {
          provider: provider,
          id_token: token,
          access_token: access_token,
          nonce: nonce,
          gotrue_meta_security: { captcha_token: captcha_token }
        }

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
        _remove_session

        domain = credentials[:domain] || credentials["domain"]
        provider_id = credentials[:provider_id] || credentials["provider_id"]
        options = credentials[:options] || credentials["options"] || {}
        redirect_to = options[:redirect_to]
        captcha_token = options[:captcha_token]
        skip_http_redirect = options.fetch(:skip_http_redirect, true)

        if domain
          data = _request("POST", "sso", body: {
            domain: domain,
            skip_http_redirect: skip_http_redirect,
            gotrue_meta_security: { captcha_token: captcha_token },
            redirect_to: redirect_to
          })
          return Helpers.parse_sso_response(data)
        end

        if provider_id
          data = _request("POST", "sso", body: {
            provider_id: provider_id,
            skip_http_redirect: skip_http_redirect,
            gotrue_meta_security: { captcha_token: captcha_token },
            redirect_to: redirect_to
          })
          return Helpers.parse_sso_response(data)
        end

        raise Errors::AuthInvalidCredentialsError,
              "You must provide either a domain or provider_id"
      end

      # Sign in with OAuth provider. Returns URL to redirect the user to.
      # @param credentials [Hash] (:provider, optional :options)
      # @return [Types::OAuthResponse]
      def sign_in_with_oauth(credentials)
        _remove_session

        provider = credentials[:provider] || credentials["provider"]
        options = credentials[:options] || credentials["options"] || {}
        redirect_to = options[:redirect_to]
        scopes = options[:scopes]
        params = (options[:query_params] || {}).dup
        params["redirect_to"] = redirect_to if redirect_to
        params["scopes"] = scopes if scopes

        url_with_qs, _ = _get_url_for_provider("#{@url}/authorize", provider, params)
        Types::OAuthResponse.new(provider: provider, url: url_with_qs)
      end

      # Resend an OTP or magic link.
      # @param credentials [Hash] (:email or :phone, :type)
      # @raise [Errors::AuthInvalidCredentialsError] if neither email nor phone provided
      def resend(credentials)
        phone = credentials[:phone] || credentials["phone"]
        email = credentials[:email] || credentials["email"]
        type = credentials[:type] || credentials["type"]
        options = credentials[:options] || credentials["options"] || {}
        captcha_token = options[:captcha_token]
        email_redirect_to = options[:email_redirect_to]

        unless email || phone
          raise Errors::AuthInvalidCredentialsError,
                "An email or phone number is required"
        end

        body = {
          type: type,
          gotrue_meta_security: { captcha_token: captcha_token }
        }
        body[:email] = email if email
        body[:phone] = phone if phone

        data = _request("POST", "resend", body: body, redirect_to: email ? email_redirect_to : nil)
        Helpers.parse_auth_otp_response(data)
      end

      # Reauthenticate the current user (requires active session).
      # @raise [Errors::AuthSessionMissing] if no active session
      def reauthenticate
        session = get_session
        raise Errors::AuthSessionMissing unless session

        data = _request("GET", "reauthenticate", jwt: session.access_token)
        Helpers.parse_auth_response(data)
      end

      # Send a password reset email. Does not require an active session.
      # @param email [String] user email
      # @param options [Hash] optional :redirect_to
      def reset_password_for_email(email, options = {})
        redirect_to = options[:redirect_to]
        captcha_token = options[:captcha_token]
        body = {
          email: email,
          gotrue_meta_security: { captcha_token: captcha_token }
        }
        _request("POST", "recover", body: body, redirect_to: redirect_to)
      end

      # Alias for {#reset_password_for_email}.
      # @param email [String] user email
      # @param options [Hash] optional :redirect_to
      def reset_password_email(email:, **options)
        reset_password_for_email(email, options)
      end

      # Update the current user's attributes.
      # @param attributes [Hash] user attributes to update (e.g., email, password, data)
      # @return [Types::UserResponse]
      # @raise [Errors::AuthSessionMissing] if no active session
      def update_user(attributes, options = {})
        session = get_session
        raise Errors::AuthSessionMissing unless session

        redirect_to = options[:email_redirect_to]
        data = _request("PUT", "user", jwt: session.access_token, body: attributes, redirect_to: redirect_to)
        response = Helpers.parse_user_response(data)

        updated_session = Types::Session.new(
          access_token: session.access_token,
          refresh_token: session.refresh_token,
          token_type: session.token_type,
          expires_in: session.expires_in,
          expires_at: session.expires_at,
          provider_token: session.provider_token,
          provider_refresh_token: session.provider_refresh_token,
          user: response.user
        )
        _save_session(updated_session)
        _notify_all_subscribers("USER_UPDATED", updated_session)

        response
      end

      # Link an OAuth identity to the current user.
      # @param credentials [Hash] (:provider, optional :options)
      # @return [Types::OAuthResponse]
      # @raise [Errors::AuthSessionMissing] if no active session
      def link_identity(credentials)
        provider = credentials[:provider] || credentials["provider"]
        options = credentials[:options] || credentials["options"] || {}
        redirect_to = options[:redirect_to]
        scopes = options[:scopes]
        params = (options[:query_params] || {}).dup
        params["redirect_to"] = redirect_to if redirect_to
        params["scopes"] = scopes if scopes
        params["skip_http_redirect"] = "true"

        url = "user/identities/authorize"
        _, query = _get_url_for_provider(url, provider, params)

        session = get_session
        raise Errors::AuthSessionMissing unless session

        response = _request("GET", url,
                            params: query,
                            jwt: session.access_token,
                            xform: ->(data) { Helpers.parse_link_identity_response(data) })
        Types::OAuthResponse.new(provider: provider, url: response.url)
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
      rescue StandardError => e
        _remove_session
        raise e
      end

      # Get JWT claims from the current session. Validates symmetric JWTs via get_user,
      # asymmetric JWTs via JWKS endpoint.
      # @return [Hash, nil] hash with "claims" key, or nil if no session
      def get_claims(jwt: nil, jwks: nil)
        token = jwt
        unless token
          session = get_session
          return nil unless session
          token = session.access_token
        end

        decoded = Helpers.decode_jwt(token)
        payload = decoded[:payload]
        header = decoded[:header]
        signature = decoded[:signature]
        raw_header = decoded[:raw]["header"]
        raw_payload = decoded[:raw]["payload"]

        Helpers.validate_exp(payload["exp"])

        # If symmetric algorithm (no kid or HS256), fallback to get_user
        if !header["kid"] || header["alg"] == "HS256"
          get_user(token)
          return { "claims" => payload, "headers" => header, "signature" => signature }
        end

        # Asymmetric JWT - verify via JWKS
        jwk_data = _fetch_jwks(header["kid"], jwks || { "keys" => [] })
        signing_key = JWT::JWK.new(jwk_data).verify_key

        digest = ALG_TO_DIGEST[header["alg"]]
        raise Errors::AuthInvalidJwtError, "Unsupported algorithm: #{header["alg"]}" unless digest

        is_valid = signing_key.verify(digest, signature, "#{raw_header}.#{raw_payload}")
        raise Errors::AuthInvalidJwtError, "Invalid JWT signature" unless is_valid

        { "claims" => payload, "headers" => header, "signature" => signature }
      end

      # --- PKCE helpers ---

      def _is_implicit_grant_flow(url)
        parsed = URI.parse(url)
        params = URI.decode_www_form(parsed.query || "").to_h
        params.key?("access_token") || params.key?("error_description")
      end

      def _get_url_for_provider(url, provider, params = {})
        params = params.dup
        if @flow_type == "pkce"
          code_verifier = Helpers.generate_pkce_verifier
          code_challenge = Helpers.generate_pkce_challenge(code_verifier)
          @storage.set_item("#{@storage_key}-code-verifier", code_verifier)
          code_challenge_method = code_verifier == code_challenge ? "plain" : "s256"
          params["code_challenge"] = code_challenge
          params["code_challenge_method"] = code_challenge_method
        end

        params["provider"] = provider
        query = URI.encode_www_form(params)
        ["#{url}?#{query}", params]
      end

      # Exchange an authorization code for a session (PKCE flow).
      # @param params [Hash] (:auth_code, optional :code_verifier, :redirect_to)
      # @return [Types::AuthResponse]
      def exchange_code_for_session(params)
        code_verifier = params[:code_verifier] || params["code_verifier"] ||
                        @storage.get_item("#{@storage_key}-code-verifier")

        data = _request("POST", "token",
                        body: {
                          auth_code: params[:auth_code] || params["auth_code"],
                          code_verifier: code_verifier
                        },
                        params: { "grant_type" => "pkce" },
                        redirect_to: params[:redirect_to] || params["redirect_to"])
        response = Helpers.parse_auth_response(data)

        @storage.remove_item("#{@storage_key}-code-verifier")

        if response.session
          _save_session(response.session)
          _notify_all_subscribers("SIGNED_IN", response.session)
        end

        response
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
        expires_at = expires_at.to_i if expires_at

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
        if @persist_session
          _save_session(current_session)
        end
        _notify_all_subscribers("SIGNED_IN", current_session)
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
        end
        @current_session = nil
        if @refresh_token_timer
          @refresh_token_timer.cancel
          @refresh_token_timer = nil
        end
      end

      def _save_session(session)
        @current_session = session

        expire_at = session.expires_at
        if expire_at
          time_now = Time.now.to_i
          expire_in = expire_at - time_now
          refresh_duration_before_expires = expire_in > EXPIRY_MARGIN ? EXPIRY_MARGIN : 0.5
          value = (expire_in - refresh_duration_before_expires) * 1000
          _start_auto_refresh_token(value)
        end

        if @persist_session && session.expires_at
          session_data = {
            access_token: session.access_token,
            refresh_token: session.refresh_token,
            token_type: session.token_type,
            expires_in: session.expires_in,
            expires_at: session.expires_at,
            provider_token: session.provider_token,
            provider_refresh_token: session.provider_refresh_token
          }
          if session.user
            user = session.user
            session_data[:user] = {
              id: user.id, aud: user.aud, role: user.role,
              email: user.email, phone: user.phone,
              email_confirmed_at: user.email_confirmed_at&.iso8601,
              phone_confirmed_at: user.phone_confirmed_at&.iso8601,
              confirmed_at: user.confirmed_at&.iso8601,
              last_sign_in_at: user.last_sign_in_at&.iso8601,
              app_metadata: user.app_metadata, user_metadata: user.user_metadata,
              identities: user.identities&.map { |i|
                {
                  id: i.id, identity_id: i.identity_id, user_id: i.user_id,
                  identity_data: i.identity_data, provider: i.provider,
                  last_sign_in_at: i.last_sign_in_at&.iso8601,
                  created_at: i.created_at&.iso8601, updated_at: i.updated_at&.iso8601
                }
              },
              factors: user.factors&.map { |f|
                {
                  id: f.id, friendly_name: f.friendly_name, factor_type: f.factor_type,
                  status: f.status,
                  created_at: f.created_at&.iso8601, updated_at: f.updated_at&.iso8601
                }
              },
              created_at: user.created_at&.iso8601, updated_at: user.updated_at&.iso8601,
              new_email: user.new_email, new_phone: user.new_phone,
              invited_at: user.invited_at&.iso8601,
              is_anonymous: user.is_anonymous,
              confirmation_sent_at: user.confirmation_sent_at&.iso8601,
              recovery_sent_at: user.recovery_sent_at&.iso8601,
              email_change_sent_at: user.email_change_sent_at&.iso8601,
              action_link: user.action_link
            }
          end
          @storage.set_item(@storage_key, JSON.generate(session_data))
        end
      end

      def _notify_all_subscribers(event, session)
        @state_change_emitters.each_value do |sub|
          sub.callback&.call(event, session)
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
          return nil unless data
          return nil unless data["access_token"] || data[:access_token]
          return nil unless data["refresh_token"] || data[:refresh_token]
          return nil unless data["expires_at"] || data[:expires_at]

          expires_at = data["expires_at"] || data[:expires_at]
          begin
            expires_at = Integer(expires_at)
            data["expires_at"] = expires_at
          rescue ArgumentError, TypeError
            return nil
          end

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
          error = params["error"]
          raise Errors::AuthImplicitGrantRedirectError.new("No error_code detected.") unless error_code
          raise Errors::AuthImplicitGrantRedirectError.new("No error detected.") unless error
          raise Errors::AuthImplicitGrantRedirectError.new(
            params["error_description"],
            details: { error: error, code: error_code }
          )
        end

        provider_token = params["provider_token"]
        provider_refresh_token = params["provider_refresh_token"]
        access_token = params["access_token"]
        raise Errors::AuthImplicitGrantRedirectError.new("No access_token detected.") unless access_token

        expires_in = params["expires_in"]
        raise Errors::AuthImplicitGrantRedirectError.new("No expires_in detected.") unless expires_in
        expires_in = expires_in.to_i

        refresh_token = params["refresh_token"]
        raise Errors::AuthImplicitGrantRedirectError.new("No refresh_token detected.") unless refresh_token

        token_type = params["token_type"]
        raise Errors::AuthImplicitGrantRedirectError.new("No token_type detected.") unless token_type

        time_now = Time.now.to_i
        expires_at = time_now + expires_in

        user_response = get_user(access_token)
        session = Types::Session.new(
          provider_token: provider_token,
          provider_refresh_token: provider_refresh_token,
          access_token: access_token,
          refresh_token: refresh_token,
          token_type: token_type,
          expires_in: expires_in,
          expires_at: expires_at,
          user: user_response.user
        )

        redirect_type = params["type"]
        [session, redirect_type]
      end

      def _fetch_jwks(kid, jwks)
        # Try supplied keys first
        jwk = (jwks["keys"] || []).find { |k| k["kid"] == kid }
        return jwk if jwk

        # Try cache
        if @jwks && @jwks_cached_at && (Time.now.to_f - @jwks_cached_at) < JWKS_TTL
          jwk = (@jwks["keys"] || []).find { |k| k["kid"] == kid }
          return jwk if jwk
        end

        # Fetch from well-known endpoint
        response = _request("GET", ".well-known/jwks.json", xform: ->(d) { Helpers.parse_jwks(d) })
        if response
          @jwks = response
          @jwks_cached_at = Time.now.to_f

          jwk = (response["keys"] || []).find { |k| k["kid"] == kid }
          raise Errors::AuthInvalidJwtError, "No matching signing key found in JWKS" unless jwk
          return jwk
        end

        raise Errors::AuthInvalidJwtError, "JWT has no valid kid"
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

        session = @client.get_session
        raise Errors::AuthSessionMissing unless session

        body = { factor_type: factor_type, friendly_name: friendly_name }

        if factor_type == "phone"
          body[:phone] = params[:phone] || params["phone"]
        else
          body[:issuer] = params[:issuer] || params["issuer"]
        end

        data = @client._request("POST", "factors", jwt: session.access_token, body: body)
        response = Types::AuthMFAEnrollResponse.from_hash(data)

        if factor_type == "totp" && response.totp&.qr_code
          response.totp.qr_code = "data:image/svg+xml;utf-8,#{response.totp.qr_code}"
        end

        response
      end

      # Create an MFA challenge for a factor.
      # @param params [Hash] (:factor_id)
      # @return [Types::AuthMFAChallengeResponse]
      def challenge(params)
        factor_id = params[:factor_id] || params["factor_id"]
        channel = params[:channel] || params["channel"]

        session = @client.get_session
        raise Errors::AuthSessionMissing unless session

        data = @client._request("POST", "factors/#{factor_id}/challenge",
                                jwt: session.access_token, body: { channel: channel })
        Types::AuthMFAChallengeResponse.from_hash(data)
      end

      # Verify an MFA challenge.
      # @param params [Hash] (:factor_id, :challenge_id, :code)
      # @return [Types::AuthMFAVerifyResponse]
      def verify(params)
        factor_id = params[:factor_id] || params["factor_id"]
        challenge_id = params[:challenge_id] || params["challenge_id"]
        code = params[:code] || params["code"]

        session = @client.get_session
        raise Errors::AuthSessionMissing unless session

        body = { factor_id: factor_id, challenge_id: challenge_id, code: code }
        data = @client._request("POST", "factors/#{factor_id}/verify",
                                jwt: session.access_token, body: body)
        response = Types::AuthMFAVerifyResponse.from_hash(data)

        # Save the new session from the verify response
        new_session = Types::Session.from_hash(data)
        if new_session&.access_token
          @client.send(:_save_session, new_session)
          @client.send(:_notify_all_subscribers, "MFA_CHALLENGE_VERIFIED", new_session)
        end

        response
      end

      # Challenge and verify in one step.
      # @param params [Hash] (:factor_id, :code)
      # @return [Types::AuthMFAVerifyResponse]
      def challenge_and_verify(params)
        challenge_response = challenge(
          factor_id: params[:factor_id] || params["factor_id"]
        )
        verify(
          factor_id: params[:factor_id] || params["factor_id"],
          challenge_id: challenge_response.id,
          code: params[:code] || params["code"]
        )
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
        user_response = @client.get_user
        factors = user_response&.user&.factors || []

        totp = factors.select { |f| f.factor_type == "totp" && f.status == "verified" }
        phone = factors.select { |f| f.factor_type == "phone" && f.status == "verified" }

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

        verified_factors = (session.user&.factors || []).select { |f| f.status == "verified" }
        next_level = verified_factors.any? ? "aal2" : aal

        Types::AuthMFAGetAuthenticatorAssuranceLevelResponse.new(
          current_level: aal,
          next_level: next_level,
          current_authentication_methods: amr
        )
      end
    end
  end
end
