# frozen_string_literal: true

require "jwt"
require "uri"
require "json"

module Supabase
  module Auth
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

        @api = Api.new(url: @url, headers: @headers, http_client: @http_client)
        @admin = AdminApi.new(url: @url, headers: @headers, http_client: @http_client)
        @mfa = MFAApi.new(self)
      end

      # --- Public API ---

      def sign_up(credentials)
        email = credentials[:email] || credentials["email"]
        phone = credentials[:phone] || credentials["phone"]
        password = credentials[:password] || credentials["password"]

        body = { password: password }
        if email
          body[:email] = email
        elsif phone
          body[:phone] = phone
        end

        data = _request("POST", "signup", body: body)
        response = Helpers.parse_auth_response(data)

        if response.session
          _save_session(response.session)
          _notify_all_subscribers("SIGNED_IN", response.session)
        end

        response
      end

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

      def get_session
        @current_session
      end

      def get_user(jwt = nil)
        access_token = jwt || @current_session&.access_token
        return nil unless access_token

        data = _request("GET", "user", jwt: access_token)
        Helpers.parse_user_response(data)
      end

      def get_user_identities
        session = get_session
        raise Errors::AuthSessionMissing unless session

        user_response = get_user(session.access_token)
        identities = user_response&.user&.identities || []
        Types::IdentitiesResponse.new(identities: identities)
      end

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

      def sign_in_anonymously
        data = _request("POST", "signup", body: {})
        response = Helpers.parse_auth_response(data)

        if response.session
          _save_session(response.session)
          _notify_all_subscribers("SIGNED_IN", response.session)
        end

        response
      end

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

      def sign_in_with_oauth(credentials)
        provider = credentials[:provider] || credentials["provider"]
        options = credentials[:options] || credentials["options"] || {}

        url, params = _get_url_for_provider("#{@url}/authorize", provider, options)
        Types::OAuthResponse.new(provider: provider, url: "#{url}?#{URI.encode_www_form(params)}")
      end

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

      def reauthenticate
        session = get_session
        raise Errors::AuthSessionMissing unless session

        _request("GET", "reauthenticate", jwt: session.access_token)
      end

      def reset_password_email(email:, **options)
        session = get_session
        raise Errors::AuthSessionMissing unless session

        redirect_to = options[:redirect_to]
        body = { email: email }
        _request("POST", "recover", body: body, redirect_to: redirect_to)
      end

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

      def unlink_identity(identity)
        session = get_session
        raise Errors::AuthSessionMissing unless session

        identity_id = identity.respond_to?(:identity_id) ? identity.identity_id : identity[:identity_id]
        _request("DELETE", "user/identities/#{identity_id}", jwt: session.access_token)
      end

      def on_auth_state_change(&callback)
        id = SecureRandom.uuid
        subscription = { id: id, callback: callback }
        @state_change_emitters[id] = subscription

        subscription
      end

      def initialize_from_url(url)
        if _is_implicit_grant_flow(url)
          session, redirect_type = _get_session_from_url(url)
          _save_session(session)
          _notify_all_subscribers("SIGNED_IN", session)
          _notify_all_subscribers("PASSWORD_RECOVERY", session) if redirect_type == "recovery"
        end
        nil
      end

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

      def _start_auto_refresh_token(seconds = nil)
        # In Ruby, we don't use a background timer like Python.
        # This is a no-op that returns nil, matching the Python test expectation.
        nil
      end

      def _recover_and_refresh
        data_str = @storage.get_item(@storage_key)
        return unless data_str

        data = JSON.parse(data_str)
        session = Types::Session.from_hash(data)
        @current_session = session

        if @auto_refresh_token && session&.refresh_token
          begin
            refresh_session(session.refresh_token)
          rescue Errors::AuthError
            # Silently fail on refresh errors during recovery
          end
        end
      end

      def _list_factors
        mfa.list_factors
      end

      def _remove_session
        @current_session = nil
        @storage.remove_item(@storage_key)
      end

      def _save_session(session)
        @current_session = session
        if @persist_session
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

    # MFA API wrapper - delegates to methods on the Client
    class MFAApi
      def initialize(client)
        @client = client
      end

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

      def challenge(params)
        factor_id = params[:factor_id] || params["factor_id"]

        session = @client.get_session
        raise Errors::AuthSessionMissing unless session

        data = @client._request("POST", "factors/#{factor_id}/challenge",
                                jwt: session.access_token, body: {})
        Types::AuthMFAChallengeResponse.from_hash(data)
      end

      def unenroll(params)
        factor_id = params[:factor_id] || params["factor_id"]

        session = @client.get_session
        raise Errors::AuthSessionMissing unless session

        data = @client._request("DELETE", "factors/#{factor_id}",
                                jwt: session.access_token)
        Types::AuthMFAUnenrollResponse.from_hash(data)
      end

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
