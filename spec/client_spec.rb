# frozen_string_literal: true

require "spec_helper"
require "jwt"
require "securerandom"

RSpec.describe Supabase::Auth::Client do
  before(:each) do
    WebMock.allow_net_connect! if defined?(WebMock)
  end

  # auth-py: test_get_claims_returns_none_when_session_is_none (test_gotrue.py:24)
  describe "#get_claims" do
    it "returns nil when session is nil" do
      client = auth_client
      claims = client.get_claims
      expect(claims).to be_nil
    end
  end

  # auth-py: test_get_claims_calls_get_user_if_symmetric_jwt (test_gotrue.py:29)
  describe "#get_claims with symmetric JWT" do
    it "calls get_user for symmetric JWT" do
      client = auth_client
      spy = allow(client).to receive(:get_user).and_call_original

      user = client.sign_up(mock_user_credentials).user
      expect(user).not_to be_nil

      claims = client.get_claims["claims"]
      expect(claims["email"]).to eq(user.email)
      expect(client).to have_received(:get_user).at_least(:once)
    end
  end

  # auth-py: test_get_claims_fetches_jwks_to_verify_asymmetric_jwt (test_gotrue.py:41)
  describe "#get_claims with asymmetric JWT" do
    it "fetches JWKS to verify asymmetric JWT" do
      client = auth_client_with_asymmetric_session

      user = client.sign_up(mock_user_credentials).user
      expect(user).not_to be_nil

      spy = allow(client).to receive(:_request).and_call_original

      claims = client.get_claims["claims"]
      expect(claims["email"]).to eq(user.email)

      expect(client).to have_received(:_request).with("GET", ".well-known/jwks.json", hash_including(:xform))

      expected_keyid = "638c54b8-28c2-4b12-9598-ba12ef610a29"
      expect(client._jwks["keys"].length).to eq(1)
      expect(client._jwks["keys"][0]["kid"]).to eq(expected_keyid)
    end
  end

  # auth-py: test_jwks_ttl_cache_behavior (test_gotrue.py:61)
  describe "#get_claims JWKS TTL cache" do
    it "caches JWKS with TTL behavior" do
      client = auth_client_with_asymmetric_session

      spy = allow(client).to receive(:_request).and_call_original

      # First call should fetch JWKS from endpoint
      user = client.sign_up(mock_user_credentials).user
      expect(user).not_to be_nil

      client.get_claims
      jwks_call_count = count_jwks_calls(client)

      # Second call within TTL should use cache
      client.get_claims
      expect(count_jwks_calls(client)).to eq(jwks_call_count)

      # Mock time to be after TTL expiry (600s)
      allow(Time).to receive(:now).and_return(Time.at(Time.now.to_f + 601))

      client.get_claims
      expect(count_jwks_calls(client)).to eq(jwks_call_count + 1)
    end
  end

  # auth-py: test_set_session_with_valid_tokens (test_gotrue.py:92)
  describe "#set_session" do
    it "sets session with valid tokens" do
      client = auth_client
      credentials = mock_user_credentials

      signup_response = client.sign_up(email: credentials[:email], password: credentials[:password])
      expect(signup_response.session).not_to be_nil

      access_token = signup_response.session.access_token
      refresh_token = signup_response.session.refresh_token

      client._remove_session

      response = client.set_session(access_token, refresh_token)

      expect(response.session).not_to be_nil
      expect(response.session.access_token).to eq(access_token)
      expect(response.session.refresh_token).to eq(refresh_token)
      expect(response.user).not_to be_nil
      expect(response.user.email).to eq(credentials[:email])
    end
  end

  # auth-py: test_set_session_with_expired_token (test_gotrue.py:123)
  describe "#set_session with expired token" do
    it "refreshes with expired token" do
      client = auth_client
      credentials = mock_user_credentials

      signup_response = client.sign_up(email: credentials[:email], password: credentials[:password])
      expect(signup_response.session).not_to be_nil

      access_token = signup_response.session.access_token
      refresh_token = signup_response.session.refresh_token

      client._remove_session

      # Create an expired token by modifying the JWT payload
      payload = Supabase::Auth::Helpers.decode_jwt(access_token)[:payload]
      payload["exp"] = Time.now.to_i - 3600 # 1 hour ago
      expired_parts = access_token.split(".")
      new_payload_segment = JWT.encode(payload, TestClients::GOTRUE_JWT_SECRET, "HS256").split(".")[1]
      expired_parts[1] = new_payload_segment
      expired_access_token = expired_parts.join(".")

      response = client.set_session(expired_access_token, refresh_token)

      expect(response.session).not_to be_nil
      expect(response.session.access_token).not_to eq(expired_access_token)
      expect(response.session.refresh_token).not_to eq(refresh_token)
      expect(response.user).not_to be_nil
      expect(response.user.email).to eq(credentials[:email])
    end
  end

  # auth-py: test_set_session_without_refresh_token (test_gotrue.py:163)
  describe "#set_session without refresh token" do
    it "raises AuthSessionMissingError for expired token without refresh token" do
      client = auth_client
      credentials = mock_user_credentials

      signup_response = client.sign_up(email: credentials[:email], password: credentials[:password])
      expect(signup_response.session).not_to be_nil

      access_token = signup_response.session.access_token
      client._remove_session

      # Create an expired token
      payload = Supabase::Auth::Helpers.decode_jwt(access_token)[:payload]
      payload["exp"] = Time.now.to_i - 3600
      expired_parts = access_token.split(".")
      new_payload_segment = JWT.encode(payload, TestClients::GOTRUE_JWT_SECRET, "HS256").split(".")[1]
      expired_parts[1] = new_payload_segment
      expired_access_token = expired_parts.join(".")

      expect { client.set_session(expired_access_token, "") }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end
  end

  # auth-py: test_set_session_with_invalid_token (test_gotrue.py:196)
  describe "#set_session with invalid token" do
    it "raises AuthInvalidJwtError for invalid token" do
      client = auth_client

      expect { client.set_session("invalid.token.here", "invalid_refresh_token") }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError)
    end
  end

  # auth-py: test_mfa_enroll (test_gotrue.py:204)
  describe "#mfa.enroll" do
    it "enrolls TOTP factor" do
      client = auth_client_with_session
      credentials = mock_user_credentials

      client.sign_up(email: credentials[:email], password: credentials[:password])

      enroll_response = client.mfa.enroll(
        issuer: "test-issuer",
        factor_type: "totp",
        friendly_name: "test-factor"
      )

      expect(enroll_response.id).not_to be_nil
      expect(enroll_response.type).to eq("totp")
      expect(enroll_response.friendly_name).to eq("test-factor")
      expect(enroll_response.totp.qr_code).not_to be_nil
    end
  end

  # auth-py: test_mfa_challenge (test_gotrue.py:228)
  describe "#mfa.challenge" do
    it "creates challenge" do
      client = auth_client
      credentials = mock_user_credentials

      signup_response = client.sign_up(email: credentials[:email], password: credentials[:password])
      expect(signup_response.session).not_to be_nil

      enroll_response = client.mfa.enroll(
        factor_type: "totp",
        issuer: "test-issuer",
        friendly_name: "test-factor"
      )

      challenge_response = client.mfa.challenge(factor_id: enroll_response.id)
      expect(challenge_response.id).not_to be_nil
      expect(challenge_response.expires_at).not_to be_nil
    end
  end

  # auth-py: test_mfa_unenroll (test_gotrue.py:252)
  describe "#mfa.unenroll" do
    it "unenrolls factor" do
      client = auth_client
      credentials = mock_user_credentials

      signup_response = client.sign_up(email: credentials[:email], password: credentials[:password])
      expect(signup_response.session).not_to be_nil

      enroll_response = client.mfa.enroll(
        factor_type: "totp",
        issuer: "test-issuer",
        friendly_name: "test-factor"
      )

      unenroll_response = client.mfa.unenroll(factor_id: enroll_response.id)
      expect(unenroll_response.id).to eq(enroll_response.id)
    end
  end

  # auth-py: test_mfa_list_factors (test_gotrue.py:275)
  describe "#mfa.list_factors" do
    it "lists factors" do
      client = auth_client
      credentials = mock_user_credentials

      signup_response = client.sign_up(email: credentials[:email], password: credentials[:password])
      expect(signup_response.session).not_to be_nil

      client.mfa.enroll(
        factor_type: "totp",
        issuer: "test-issuer",
        friendly_name: "test-factor"
      )

      list_response = client.mfa.list_factors
      expect(list_response.all.length).to eq(1)
    end
  end

  # auth-py: test_initialize_from_url (test_gotrue.py:298)
  describe "#initialize_from_url" do
    it "handles implicit grant flow detection, session initialization, errors, and no-op" do
      client = auth_client

      # Test _is_implicit_grant_flow
      url_with_token = "http://example.com/?access_token=test_token&other=value"
      expect(client._is_implicit_grant_flow(url_with_token)).to eq(true)

      url_with_error = "http://example.com/?error_description=test_error&other=value"
      expect(client._is_implicit_grant_flow(url_with_error)).to eq(true)

      url_without_token = "http://example.com/?other=value"
      expect(client._is_implicit_grant_flow(url_without_token)).to eq(false)

      # Test successful initialization with tokens in URL
      mock_user = Supabase::Auth::Types::User.new(
        id: "user123",
        email: "test@example.com",
        app_metadata: {},
        user_metadata: {},
        aud: "authenticated",
        created_at: Time.parse("2023-01-01T00:00:00Z"),
        confirmed_at: Time.parse("2023-01-01T00:00:00Z"),
        last_sign_in_at: Time.parse("2023-01-01T00:00:00Z"),
        role: "authenticated",
        updated_at: Time.parse("2023-01-01T00:00:00Z")
      )

      mock_user_response = Supabase::Auth::Types::UserResponse.new(user: mock_user)

      good_url = "http://example.com/?access_token=mock_access_token&refresh_token=mock_refresh_token&expires_in=3600&token_type=bearer"

      allow(client).to receive(:get_user).and_return(mock_user_response)
      allow(client).to receive(:_save_session).and_call_original
      allow(client).to receive(:_notify_all_subscribers).and_call_original

      result = client.initialize_from_url(good_url)

      expect(client).to have_received(:get_user).with("mock_access_token")
      expect(client).to have_received(:_save_session).once
      expect(client).to have_received(:_notify_all_subscribers).with("SIGNED_IN", anything)
      expect(result).to be_nil

      # Verify the session was saved correctly
      session = client.get_session
      expect(session).not_to be_nil
      expect(session.access_token).to eq("mock_access_token")
      expect(session.refresh_token).to eq("mock_refresh_token")
      expect(session.expires_in).to eq(3600)

      # Test URL with error
      error_url = "http://example.com/?error=invalid_request&error_description=Invalid+request&error_code=400"

      expect {
        client.initialize_from_url(error_url)
      }.to raise_error(Supabase::Auth::Errors::AuthImplicitGrantRedirectError, /Invalid request/)

      # Test URL without auth params - should not throw and not call _get_session_from_url
      invalid_url = "http://example.com/?foo=bar"
      result = client.initialize_from_url(invalid_url)
      expect(result).to be_nil
    end
  end

  # auth-py: test_exchange_code_for_session (test_gotrue.py:393)
  describe "#exchange_code_for_session (PKCE)" do
    it "verifies code_challenge and code_challenge_method params are set and code_verifier is stored" do
      client = auth_client

      expect(["implicit", "pkce"]).to include(client._flow_type)

      storage_key = "#{client._storage_key}-code-verifier"

      # Set flow type to pkce
      client._flow_type = "pkce"

      # Test PKCE URL generation
      provider = "github"
      url, params = client._get_url_for_provider("#{client._url}/authorize", provider, {})

      expect(params).to include("code_challenge")
      expect(params).to include("code_challenge_method")

      # Verify the code verifier was stored
      code_verifier = client._storage.get_item(storage_key)
      expect(code_verifier).not_to be_nil
    end
  end

  # auth-py: test_get_authenticator_assurance_level (test_gotrue.py:420)
  describe "#mfa.get_authenticator_assurance_level" do
    it "returns authenticator assurance level" do
      client = auth_client
      credentials = mock_user_credentials

      # Without a session, should return null values
      aal_response = client.mfa.get_authenticator_assurance_level
      expect(aal_response.current_level).to be_nil
      expect(aal_response.next_level).to be_nil
      expect(aal_response.current_authentication_methods).to eq([])

      # Sign up to get a valid session
      signup_response = client.sign_up(email: credentials[:email], password: credentials[:password])
      expect(signup_response.session).not_to be_nil

      # With a session, should return authentication methods
      aal_response = client.mfa.get_authenticator_assurance_level
      expect(aal_response.current_authentication_methods).not_to be_nil
    end
  end

  # auth-py: test_link_identity (test_gotrue.py:445)
  describe "#link_identity" do
    it "constructs OAuth URL for identity linking" do
      client = auth_client
      credentials = mock_user_credentials

      signup_response = client.sign_up(email: credentials[:email], password: credentials[:password])
      expect(signup_response.session).not_to be_nil

      mock_url = "http://example.com/authorize?provider=github"
      mock_params = { "provider" => "github" }
      allow(client).to receive(:_get_url_for_provider).and_return([mock_url, mock_params])

      allow(client).to receive(:_request).and_return(
        Supabase::Auth::Types::OAuthResponse.new(provider: "github", url: mock_url)
      )

      response = client.link_identity(provider: "github")

      expect(response.provider).to eq("github")
      expect(response.url).to eq(mock_url)
    end
  end

  # auth-py: test_get_user_identities (test_gotrue.py:480)
  describe "#get_user_identities" do
    it "gets user identities" do
      client = auth_client
      credentials = mock_user_credentials

      signup_response = client.sign_up(email: credentials[:email], password: credentials[:password])
      expect(signup_response.session).not_to be_nil

      identities_response = client.get_user_identities
      expect(identities_response).not_to be_nil
      expect(identities_response).to respond_to(:identities)
    end
  end

  # auth-py: test_unlink_identity (test_gotrue.py:500)
  describe "#unlink_identity" do
    it "sends DELETE request to unlink identity" do
      client = auth_client
      credentials = mock_user_credentials

      signup_response = client.sign_up(email: credentials[:email], password: credentials[:password])
      expect(signup_response.session).not_to be_nil

      mock_identity = Supabase::Auth::Types::UserIdentity.new(
        id: "user-id",
        identity_id: "identity-id-1",
        user_id: "user-id",
        identity_data: { "email" => "user@example.com" },
        provider: "github",
        created_at: Time.parse("2023-01-01T00:00:00Z"),
        last_sign_in_at: Time.parse("2023-01-01T00:00:00Z"),
        updated_at: Time.parse("2023-01-01T00:00:00Z")
      )

      allow(client).to receive(:_request).and_return(nil)

      client.unlink_identity(mock_identity)

      expect(client).to have_received(:_request).with(
        "DELETE",
        "user/identities/identity-id-1",
        jwt: signup_response.session.access_token
      )
    end
  end

  # auth-py: test_verify_otp (test_gotrue.py:557)
  describe "#verify_otp" do
    it "verifies OTP with correct params" do
      client = auth_client

      mock_user = Supabase::Auth::Types::User.new(
        id: "test-user-id",
        app_metadata: {},
        user_metadata: {},
        aud: "test-aud",
        email: "test@example.com",
        phone: "",
        created_at: Time.parse("2023-01-01T00:00:00Z"),
        confirmed_at: Time.parse("2023-01-01T00:00:00Z"),
        last_sign_in_at: Time.parse("2023-01-01T00:00:00Z"),
        role: "",
        updated_at: Time.parse("2023-01-01T00:00:00Z")
      )

      mock_session = Supabase::Auth::Types::Session.new(
        access_token: "mock-access-token",
        refresh_token: "mock-refresh-token",
        expires_in: 3600,
        expires_at: Time.now.to_i + 3600,
        token_type: "bearer",
        user: mock_user
      )

      # Mock _request to return data that parse_auth_response can handle
      mock_data = {
        "access_token" => "mock-access-token",
        "refresh_token" => "mock-refresh-token",
        "expires_in" => 3600,
        "expires_at" => Time.now.to_i + 3600,
        "token_type" => "bearer",
        "user" => {
          "id" => "test-user-id",
          "app_metadata" => {},
          "user_metadata" => {},
          "aud" => "test-aud",
          "email" => "test@example.com",
          "phone" => "",
          "created_at" => "2023-01-01T00:00:00Z",
          "confirmed_at" => "2023-01-01T00:00:00Z",
          "last_sign_in_at" => "2023-01-01T00:00:00Z",
          "role" => "",
          "updated_at" => "2023-01-01T00:00:00Z"
        }
      }

      allow(client).to receive(:_request).and_return(mock_data)
      allow(client).to receive(:_save_session).and_call_original

      params = {
        type: "sms",
        phone: "+11234567890",
        token: "123456",
        options: { redirect_to: "https://example.com/callback" }
      }

      response = client.verify_otp(params)

      expect(client).to have_received(:_request).once
      call_args = nil
      expect(client).to have_received(:_request) do |method, path, **kwargs|
        call_args = { method: method, path: path, kwargs: kwargs }
      end

      expect(call_args[:method]).to eq("POST")
      expect(call_args[:path]).to eq("verify")
      expect(call_args[:kwargs][:body][:phone]).to eq("+11234567890")
      expect(call_args[:kwargs][:body][:token]).to eq("123456")
      expect(call_args[:kwargs][:redirect_to]).to eq("https://example.com/callback")

      expect(client).to have_received(:_save_session)
      expect(response.session).not_to be_nil
    end
  end

  # auth-py: test_sign_in_with_password (test_gotrue.py:623)
  describe "#sign_in_with_password" do
    it "signs in with password (success, wrong password, empty credentials)" do
      client = auth_client
      credentials = mock_user_credentials

      # First create a user
      signup_response = client.sign_up(email: credentials[:email], password: credentials[:password])
      expect(signup_response.session).not_to be_nil

      # Test signing in with the same credentials
      signin_response = client.sign_in_with_password(
        email: credentials[:email],
        password: credentials[:password]
      )

      expect(signin_response.session).not_to be_nil
      expect(signin_response.user).not_to be_nil
      expect(signin_response.user.email).to eq(credentials[:email])

      # Test error case: wrong password
      test_client = auth_client
      expect {
        test_client.sign_in_with_password(
          email: credentials[:email],
          password: "wrong_password"
        )
      }.to raise_error(Supabase::Auth::Errors::AuthApiError)

      # Test error case: missing credentials
      expect {
        test_client.sign_in_with_password({})
      }.to raise_error(Supabase::Auth::Errors::AuthInvalidCredentialsError)
    end
  end

  # auth-py: test_sign_in_with_otp (test_gotrue.py:674)
  describe "#sign_in_with_otp" do
    it "signs in with OTP (email, phone, missing credentials)" do
      client = auth_client
      email = "test-#{SecureRandom.uuid}@example.com"

      # Test email OTP
      email_client = auth_client
      mock_response_data = { "message_id" => "mock-message-id" }
      allow(email_client).to receive(:_request).and_return(mock_response_data)

      response = email_client.sign_in_with_otp(
        email: email,
        options: {
          email_redirect_to: "https://example.com/callback",
          should_create_user: true,
          data: { "custom" => "data" },
          captcha_token: "mock-captcha-token"
        }
      )

      expect(email_client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("otp")
        expect(kwargs[:body][:email]).to eq(email)
        expect(kwargs[:body][:create_user]).to eq(true)
        expect(kwargs[:body][:data]).to eq({ "custom" => "data" })
        expect(kwargs[:body][:gotrue_meta_security][:captcha_token]).to eq("mock-captcha-token")
        expect(kwargs[:redirect_to]).to eq("https://example.com/callback")
      end

      # Test phone OTP
      phone = "+11234567890"
      phone_client = auth_client
      allow(phone_client).to receive(:_request).and_return({ "message_id" => "mock-message-id" })

      response = phone_client.sign_in_with_otp(
        phone: phone,
        options: {
          should_create_user: true,
          data: { "custom" => "data" },
          channel: "whatsapp",
          captcha_token: "mock-captcha-token"
        }
      )

      expect(phone_client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("otp")
        expect(kwargs[:body][:phone]).to eq(phone)
        expect(kwargs[:body][:channel]).to eq("whatsapp")
        expect(kwargs[:redirect_to]).to be_nil
      end

      # Test missing credentials
      expect {
        client.sign_in_with_otp({})
      }.to raise_error(Supabase::Auth::Errors::AuthInvalidCredentialsError)
    end
  end

  # auth-py: test_sign_out (test_gotrue.py:771)
  describe "#sign_out" do
    it "handles global scope, local scope, others scope, no session, and admin error suppression" do
      mock_user = Supabase::Auth::Types::User.new(
        id: "user123",
        email: "test@example.com",
        app_metadata: {},
        user_metadata: {},
        aud: "authenticated",
        created_at: Time.parse("2023-01-01T00:00:00Z"),
        confirmed_at: Time.parse("2023-01-01T00:00:00Z"),
        last_sign_in_at: Time.parse("2023-01-01T00:00:00Z"),
        role: "authenticated",
        updated_at: Time.parse("2023-01-01T00:00:00Z")
      )

      mock_session = Supabase::Auth::Types::Session.new(
        access_token: "mock_access_token",
        refresh_token: "mock_refresh_token",
        expires_in: 3600,
        token_type: "bearer",
        user: mock_user
      )

      # Test sign_out with "global" scope (default)
      client1 = auth_client
      allow(client1).to receive(:get_session).and_return(mock_session)
      allow(client1.admin).to receive(:sign_out)
      allow(client1).to receive(:_remove_session).and_call_original
      allow(client1).to receive(:_notify_all_subscribers).and_call_original

      client1.sign_out

      expect(client1.admin).to have_received(:sign_out).with("mock_access_token", "global").once
      expect(client1).to have_received(:_remove_session).once
      expect(client1).to have_received(:_notify_all_subscribers).with("SIGNED_OUT", nil).once

      # Test sign_out with "local" scope
      client2 = auth_client
      allow(client2).to receive(:get_session).and_return(mock_session)
      allow(client2.admin).to receive(:sign_out)
      allow(client2).to receive(:_remove_session).and_call_original
      allow(client2).to receive(:_notify_all_subscribers).and_call_original

      client2.sign_out(scope: "local")

      expect(client2.admin).to have_received(:sign_out).with("mock_access_token", "local").once
      expect(client2).to have_received(:_remove_session).once
      expect(client2).to have_received(:_notify_all_subscribers).with("SIGNED_OUT", nil).once

      # Test sign_out with "others" scope
      client3 = auth_client
      allow(client3).to receive(:get_session).and_return(mock_session)
      allow(client3.admin).to receive(:sign_out)
      allow(client3).to receive(:_remove_session)
      allow(client3).to receive(:_notify_all_subscribers)

      client3.sign_out(scope: "others")

      expect(client3.admin).to have_received(:sign_out).with("mock_access_token", "others").once
      expect(client3).not_to have_received(:_remove_session)
      expect(client3).not_to have_received(:_notify_all_subscribers)

      # Test sign_out with no session
      client4 = auth_client
      allow(client4).to receive(:get_session).and_return(nil)
      allow(client4.admin).to receive(:sign_out)
      allow(client4).to receive(:_remove_session).and_call_original
      allow(client4).to receive(:_notify_all_subscribers).and_call_original

      client4.sign_out

      expect(client4.admin).not_to have_received(:sign_out)
      expect(client4).to have_received(:_remove_session).once
      expect(client4).to have_received(:_notify_all_subscribers).with("SIGNED_OUT", nil).once

      # Test when admin.sign_out raises an error
      client5 = auth_client
      allow(client5).to receive(:get_session).and_return(mock_session)
      allow(client5.admin).to receive(:sign_out).and_raise(
        Supabase::Auth::Errors::AuthApiError.new("Test error", status: 401, code: "auth_error")
      )
      allow(client5).to receive(:_remove_session).and_call_original
      allow(client5).to receive(:_notify_all_subscribers).and_call_original

      client5.sign_out

      expect(client5).to have_received(:_remove_session).once
      expect(client5).to have_received(:_notify_all_subscribers).with("SIGNED_OUT", nil).once
    end
  end

  private

  def count_jwks_calls(client)
    # Count the number of times _request was called with JWKS path
    RSpec::Mocks.space.proxy_for(client).instance_variable_get(:@messages_received)
      &.count { |msg| msg[0] == :_request && msg[1]&.dig(1) == ".well-known/jwks.json" } || 0
  rescue StandardError
    0
  end
end
