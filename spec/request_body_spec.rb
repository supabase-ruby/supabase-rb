# frozen_string_literal: true

require "spec_helper"
require "jwt"
require "securerandom"

# These tests verify that the Ruby client sends the correct request bodies,
# matching the Python auth-py reference implementation.
# Each test mocks _request to capture and assert on the exact arguments.
RSpec.describe "Request body assertions" do
  let(:mock_user) do
    Supabase::Auth::Types::User.new(
      id: "test-user-id",
      app_metadata: {},
      user_metadata: {},
      aud: "test-aud",
      email: "test@example.com",
      phone: "",
      created_at: Time.parse("2023-01-01T00:00:00Z"),
      confirmed_at: Time.parse("2023-01-01T00:00:00Z"),
      last_sign_in_at: Time.parse("2023-01-01T00:00:00Z"),
      role: "authenticated",
      updated_at: Time.parse("2023-01-01T00:00:00Z")
    )
  end

  let(:mock_session) do
    Supabase::Auth::Types::Session.new(
      access_token: "mock-access-token",
      refresh_token: "mock-refresh-token",
      expires_in: 3600,
      expires_at: Time.now.to_i + 3600,
      token_type: "bearer",
      user: mock_user
    )
  end

  let(:mock_auth_data) do
    {
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
        "role" => "authenticated",
        "updated_at" => "2023-01-01T00:00:00Z"
      }
    }
  end

  let(:client) do
    Supabase::Auth::Client.new(
      url: "http://localhost:9998",
      auto_refresh_token: false,
      persist_session: false
    )
  end

  # Helper to set up a mock session on the client
  def setup_session(client, session)
    client.instance_variable_set(:@current_session, session)
  end

  describe "#sign_up request body" do
    it "constructs email signup body matching Python (email, password, data, gotrue_meta_security)" do
      allow(client).to receive(:_request).and_return(mock_auth_data)

      client.sign_up(
        email: "test@example.com",
        password: "secret123",
        options: { data: { "name" => "Test" }, captcha_token: "cap-123", redirect_to: "https://app.com" }
      )

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("signup")
        expect(kwargs[:body][:email]).to eq("test@example.com")
        expect(kwargs[:body][:password]).to eq("secret123")
        expect(kwargs[:body][:data]).to eq({ "name" => "Test" })
        expect(kwargs[:body][:gotrue_meta_security]).to eq({ captcha_token: "cap-123" })
        expect(kwargs[:body]).not_to have_key(:phone)
        expect(kwargs[:body]).not_to have_key(:channel)
        expect(kwargs[:redirect_to]).to eq("https://app.com")
      end
    end

    it "constructs phone signup body matching Python (phone, password, data, channel, gotrue_meta_security)" do
      allow(client).to receive(:_request).and_return(mock_auth_data)

      client.sign_up(
        phone: "+1234567890",
        password: "secret123",
        options: { data: { "name" => "Test" }, channel: "whatsapp", captcha_token: "cap-456" }
      )

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("signup")
        expect(kwargs[:body][:phone]).to eq("+1234567890")
        expect(kwargs[:body][:password]).to eq("secret123")
        expect(kwargs[:body][:data]).to eq({ "name" => "Test" })
        expect(kwargs[:body][:channel]).to eq("whatsapp")
        expect(kwargs[:body][:gotrue_meta_security]).to eq({ captcha_token: "cap-456" })
        expect(kwargs[:body]).not_to have_key(:email)
        # Phone signup does not pass redirect_to to _request (matching Python)
        expect(kwargs[:redirect_to]).to be_nil
      end
    end

    it "defaults channel to 'sms' for phone signup" do
      allow(client).to receive(:_request).and_return(mock_auth_data)

      client.sign_up(phone: "+1234567890", password: "secret123")

      expect(client).to have_received(:_request) do |_method, _path, **kwargs|
        expect(kwargs[:body][:channel]).to eq("sms")
      end
    end

    it "defaults data to {} for signup" do
      allow(client).to receive(:_request).and_return(mock_auth_data)

      client.sign_up(email: "test@example.com", password: "secret123")

      expect(client).to have_received(:_request) do |_method, _path, **kwargs|
        expect(kwargs[:body][:data]).to eq({})
      end
    end

    it "falls back from email_redirect_to to redirect_to" do
      allow(client).to receive(:_request).and_return(mock_auth_data)

      client.sign_up(
        email: "test@example.com",
        password: "secret123",
        options: { email_redirect_to: "https://fallback.com" }
      )

      expect(client).to have_received(:_request) do |_method, _path, **kwargs|
        expect(kwargs[:redirect_to]).to eq("https://fallback.com")
      end
    end

    it "raises AuthInvalidCredentialsError when neither email nor phone" do
      expect {
        client.sign_up(password: "secret123")
      }.to raise_error(Supabase::Auth::Errors::AuthInvalidCredentialsError)
    end

    it "calls _remove_session before signup" do
      allow(client).to receive(:_request).and_return(mock_auth_data)
      allow(client).to receive(:_remove_session).and_call_original

      client.sign_up(email: "test@example.com", password: "secret123")

      expect(client).to have_received(:_remove_session).at_least(:once)
    end

    it "saves session and notifies SIGNED_IN on successful signup with session" do
      allow(client).to receive(:_request).and_return(mock_auth_data)
      events = []
      client.on_auth_state_change { |event, _session| events << event }

      response = client.sign_up(email: "test@example.com", password: "secret123")

      expect(response).to be_a(Supabase::Auth::Types::AuthResponse)
      expect(response.session).not_to be_nil
      expect(events).to include("SIGNED_IN")
    end
  end

  describe "#sign_in_with_password request body" do
    it "includes data and gotrue_meta_security" do
      allow(client).to receive(:_request).and_return(mock_auth_data)

      client.sign_in_with_password(
        email: "test@example.com",
        password: "secret123",
        options: { data: { "foo" => "bar" }, captcha_token: "captcha-abc" }
      )

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("token")
        expect(kwargs[:body][:email]).to eq("test@example.com")
        expect(kwargs[:body][:password]).to eq("secret123")
        expect(kwargs[:body][:data]).to eq({ "foo" => "bar" })
        expect(kwargs[:body][:gotrue_meta_security]).to eq({ captcha_token: "captcha-abc" })
        expect(kwargs[:params]).to eq({ "grant_type" => "password" })
      end
    end

    it "calls _remove_session before sign-in" do
      allow(client).to receive(:_request).and_return(mock_auth_data)
      allow(client).to receive(:_remove_session).and_call_original

      client.sign_in_with_password(email: "test@example.com", password: "secret123")

      expect(client).to have_received(:_remove_session).at_least(:once)
    end
  end

  describe "#sign_in_with_id_token request body" do
    it "includes access_token, nonce, and gotrue_meta_security" do
      allow(client).to receive(:_request).and_return(mock_auth_data)

      client.sign_in_with_id_token(
        provider: "google",
        token: "id-token-123",
        access_token: "provider-access-token",
        nonce: "nonce-abc",
        options: { captcha_token: "captcha-xyz" }
      )

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("token")
        expect(kwargs[:body][:provider]).to eq("google")
        expect(kwargs[:body][:id_token]).to eq("id-token-123")
        expect(kwargs[:body][:access_token]).to eq("provider-access-token")
        expect(kwargs[:body][:nonce]).to eq("nonce-abc")
        expect(kwargs[:body][:gotrue_meta_security]).to eq({ captcha_token: "captcha-xyz" })
        expect(kwargs[:params]).to eq({ "grant_type" => "id_token" })
      end
    end

    it "calls _remove_session before sign-in" do
      allow(client).to receive(:_request).and_return(mock_auth_data)
      allow(client).to receive(:_remove_session).and_call_original

      client.sign_in_with_id_token(provider: "google", token: "id-token-123")

      expect(client).to have_received(:_remove_session).at_least(:once)
    end
  end

  describe "#sign_in_with_sso request body" do
    it "includes skip_http_redirect, gotrue_meta_security, redirect_to for domain" do
      allow(client).to receive(:_request).and_return({ "url" => "https://sso.example.com" })

      client.sign_in_with_sso(
        domain: "example.com",
        options: { redirect_to: "https://app.example.com", captcha_token: "captcha-sso" }
      )

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("sso")
        expect(kwargs[:body][:domain]).to eq("example.com")
        expect(kwargs[:body][:skip_http_redirect]).to eq(true)
        expect(kwargs[:body][:gotrue_meta_security]).to eq({ captcha_token: "captcha-sso" })
        expect(kwargs[:body][:redirect_to]).to eq("https://app.example.com")
      end
    end

    it "includes skip_http_redirect for provider_id" do
      allow(client).to receive(:_request).and_return({ "url" => "https://sso.example.com" })

      client.sign_in_with_sso(provider_id: "provider-uuid")

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(kwargs[:body][:provider_id]).to eq("provider-uuid")
        expect(kwargs[:body][:skip_http_redirect]).to eq(true)
      end
    end

    it "raises error when neither domain nor provider_id given" do
      expect { client.sign_in_with_sso({}) }.to raise_error(
        Supabase::Auth::Errors::AuthInvalidCredentialsError
      )
    end

    it "calls _remove_session before sign-in" do
      allow(client).to receive(:_request).and_return({ "url" => "https://sso.example.com" })
      allow(client).to receive(:_remove_session).and_call_original

      client.sign_in_with_sso(domain: "example.com")

      expect(client).to have_received(:_remove_session).at_least(:once)
    end
  end

  describe "#sign_in_with_oauth request body" do
    it "includes redirect_to, scopes, and query_params in URL" do
      response = client.sign_in_with_oauth(
        provider: "github",
        options: {
          redirect_to: "https://app.example.com/callback",
          scopes: "read:user",
          query_params: { "extra" => "param" }
        }
      )

      expect(response.provider).to eq("github")
      url = response.url
      expect(url).to include("provider=github")
      expect(url).to include("redirect_to=")
      expect(url).to include("scopes=read")
      expect(url).to include("extra=param")
    end

    it "calls _remove_session before sign-in" do
      allow(client).to receive(:_remove_session).and_call_original

      client.sign_in_with_oauth(provider: "github")

      expect(client).to have_received(:_remove_session)
    end
  end

  describe "#sign_in_anonymously request body" do
    it "includes data and gotrue_meta_security" do
      allow(client).to receive(:_request).and_return(mock_auth_data)

      client.sign_in_anonymously(options: { data: { "anon" => true }, captcha_token: "captcha-anon" })

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("signup")
        expect(kwargs[:body][:data]).to eq({ "anon" => true })
        expect(kwargs[:body][:gotrue_meta_security]).to eq({ captcha_token: "captcha-anon" })
      end
    end

    it "sends default empty data when no credentials" do
      allow(client).to receive(:_request).and_return(mock_auth_data)

      client.sign_in_anonymously

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(kwargs[:body][:data]).to eq({})
        expect(kwargs[:body][:gotrue_meta_security]).to eq({ captcha_token: nil })
      end
    end

    it "calls _remove_session before sign-in" do
      allow(client).to receive(:_request).and_return(mock_auth_data)
      allow(client).to receive(:_remove_session).and_call_original

      client.sign_in_anonymously

      expect(client).to have_received(:_remove_session).at_least(:once)
    end
  end

  describe "#verify_otp request body" do
    it "includes gotrue_meta_security and calls _remove_session" do
      allow(client).to receive(:_request).and_return(mock_auth_data)
      allow(client).to receive(:_remove_session).and_call_original

      client.verify_otp(
        type: "sms",
        phone: "+1234567890",
        token: "123456",
        options: { captcha_token: "captcha-otp", redirect_to: "https://example.com" }
      )

      expect(client).to have_received(:_remove_session).at_least(:once)
      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("verify")
        expect(kwargs[:body][:type]).to eq("sms")
        expect(kwargs[:body][:phone]).to eq("+1234567890")
        expect(kwargs[:body][:token]).to eq("123456")
        expect(kwargs[:body][:gotrue_meta_security]).to eq({ captcha_token: "captcha-otp" })
        expect(kwargs[:redirect_to]).to eq("https://example.com")
      end
    end
  end

  describe "#sign_in_with_otp request body" do
    it "constructs email OTP body matching Python (email, data, create_user, gotrue_meta_security)" do
      allow(client).to receive(:_request).and_return({ "message_id" => "msg-id" })

      client.sign_in_with_otp(
        email: "test@example.com",
        options: {
          data: { "key" => "val" },
          should_create_user: false,
          captcha_token: "cap-otp",
          email_redirect_to: "https://app.com/magic"
        }
      )

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("otp")
        expect(kwargs[:body][:email]).to eq("test@example.com")
        expect(kwargs[:body][:data]).to eq({ "key" => "val" })
        expect(kwargs[:body][:create_user]).to eq(false)
        expect(kwargs[:body][:gotrue_meta_security]).to eq({ captcha_token: "cap-otp" })
        expect(kwargs[:body]).not_to have_key(:phone)
        expect(kwargs[:body]).not_to have_key(:channel)
        expect(kwargs[:redirect_to]).to eq("https://app.com/magic")
      end
    end

    it "constructs phone OTP body matching Python (phone, data, create_user, channel, gotrue_meta_security)" do
      allow(client).to receive(:_request).and_return({ "message_id" => "msg-id" })

      client.sign_in_with_otp(
        phone: "+1234567890",
        options: { channel: "whatsapp", captcha_token: "cap-phone" }
      )

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("otp")
        expect(kwargs[:body][:phone]).to eq("+1234567890")
        expect(kwargs[:body][:channel]).to eq("whatsapp")
        expect(kwargs[:body][:create_user]).to eq(true)
        expect(kwargs[:body][:gotrue_meta_security]).to eq({ captcha_token: "cap-phone" })
        expect(kwargs[:body]).not_to have_key(:email)
        # Phone OTP does not pass redirect_to (matching Python)
        expect(kwargs[:redirect_to]).to be_nil
      end
    end

    it "defaults should_create_user to true and data to nil (matching Python)" do
      allow(client).to receive(:_request).and_return({ "message_id" => "msg-id" })

      client.sign_in_with_otp(email: "test@example.com")

      expect(client).to have_received(:_request) do |_method, _path, **kwargs|
        expect(kwargs[:body][:create_user]).to eq(true)
        expect(kwargs[:body][:data]).to be_nil
      end
    end

    it "defaults channel to 'sms' for phone OTP" do
      allow(client).to receive(:_request).and_return({ "message_id" => "msg-id" })

      client.sign_in_with_otp(phone: "+1234567890")

      expect(client).to have_received(:_request) do |_method, _path, **kwargs|
        expect(kwargs[:body][:channel]).to eq("sms")
      end
    end

    it "raises AuthInvalidCredentialsError when neither email nor phone" do
      expect {
        client.sign_in_with_otp({})
      }.to raise_error(Supabase::Auth::Errors::AuthInvalidCredentialsError)
    end

    it "calls _remove_session before OTP" do
      allow(client).to receive(:_request).and_return({ "message_id" => "msg-id" })
      allow(client).to receive(:_remove_session).and_call_original

      client.sign_in_with_otp(email: "test@example.com")

      expect(client).to have_received(:_remove_session).at_least(:once)
    end

    it "returns AuthOtpResponse" do
      allow(client).to receive(:_request).and_return({ "message_id" => "msg-id" })

      response = client.sign_in_with_otp(email: "test@example.com")

      expect(response).to be_a(Supabase::Auth::Types::AuthOtpResponse)
    end
  end

  describe "#resend request body" do
    it "includes gotrue_meta_security and email_redirect_to" do
      allow(client).to receive(:_request).and_return({ "message_id" => "msg-id" })

      client.resend(
        email: "test@example.com",
        type: "signup",
        options: { captcha_token: "captcha-resend", email_redirect_to: "https://example.com/verify" }
      )

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("resend")
        expect(kwargs[:body][:type]).to eq("signup")
        expect(kwargs[:body][:email]).to eq("test@example.com")
        expect(kwargs[:body][:gotrue_meta_security]).to eq({ captcha_token: "captcha-resend" })
        expect(kwargs[:redirect_to]).to eq("https://example.com/verify")
      end
    end

    it "does not pass redirect_to for phone resend" do
      allow(client).to receive(:_request).and_return({ "message_id" => "msg-id" })

      client.resend(
        phone: "+1234567890",
        type: "sms",
        options: { email_redirect_to: "https://example.com/verify" }
      )

      expect(client).to have_received(:_request) do |_method, _path, **kwargs|
        expect(kwargs[:redirect_to]).to be_nil
      end
    end
  end

  describe "#reset_password_for_email request body" do
    it "includes gotrue_meta_security" do
      allow(client).to receive(:_request).and_return({})

      client.reset_password_for_email("test@example.com", captcha_token: "captcha-reset", redirect_to: "https://example.com/reset")

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("recover")
        expect(kwargs[:body][:email]).to eq("test@example.com")
        expect(kwargs[:body][:gotrue_meta_security]).to eq({ captcha_token: "captcha-reset" })
        expect(kwargs[:redirect_to]).to eq("https://example.com/reset")
      end
    end
  end

  describe "#update_user request body" do
    it "passes email_redirect_to as redirect_to" do
      setup_session(client, mock_session)
      allow(client).to receive(:_request).and_return({
        "user" => mock_auth_data["user"]
      })

      client.update_user({ email: "new@example.com" }, { email_redirect_to: "https://example.com/confirm" })

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("PUT")
        expect(path).to eq("user")
        expect(kwargs[:body]).to eq({ email: "new@example.com" })
        expect(kwargs[:redirect_to]).to eq("https://example.com/confirm")
        expect(kwargs[:jwt]).to eq("mock-access-token")
      end
    end
  end

  describe "#link_identity request body" do
    it "includes scopes, redirect_to, skip_http_redirect in query params" do
      setup_session(client, mock_session)
      allow(client).to receive(:_request).and_return(
        Supabase::Auth::Types::LinkIdentityResponse.new(url: "https://provider.com/auth")
      )

      response = client.link_identity(
        provider: "github",
        options: {
          redirect_to: "https://app.example.com",
          scopes: "repo",
          query_params: { "extra" => "value" }
        }
      )

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("GET")
        expect(path).to eq("user/identities/authorize")
        expect(kwargs[:jwt]).to eq("mock-access-token")
        params = kwargs[:params]
        expect(params["redirect_to"]).to eq("https://app.example.com")
        expect(params["scopes"]).to eq("repo")
        expect(params["skip_http_redirect"]).to eq("true")
        expect(params["extra"]).to eq("value")
        expect(params["provider"]).to eq("github")
      end

      expect(response.provider).to eq("github")
    end
  end

  describe "MFA enroll request body" do
    it "includes phone for phone factor type" do
      setup_session(client, mock_session)
      allow(client).to receive(:_request).and_return({
        "id" => "factor-id",
        "type" => "phone",
        "friendly_name" => "my-phone"
      })

      client.mfa.enroll(factor_type: "phone", friendly_name: "my-phone", phone: "+1234567890")

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("factors")
        expect(kwargs[:body][:factor_type]).to eq("phone")
        expect(kwargs[:body][:phone]).to eq("+1234567890")
        expect(kwargs[:body]).not_to have_key(:issuer)
      end
    end

    it "includes issuer for totp factor type" do
      setup_session(client, mock_session)
      allow(client).to receive(:_request).and_return({
        "id" => "factor-id",
        "type" => "totp",
        "friendly_name" => "my-totp",
        "totp" => { "qr_code" => "<svg>test</svg>", "secret" => "secret", "uri" => "otpauth://..." }
      })

      response = client.mfa.enroll(factor_type: "totp", friendly_name: "my-totp", issuer: "MyApp")

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(kwargs[:body][:factor_type]).to eq("totp")
        expect(kwargs[:body][:issuer]).to eq("MyApp")
        expect(kwargs[:body]).not_to have_key(:phone)
      end

      # QR code should have data URI prefix
      expect(response.totp.qr_code).to start_with("data:image/svg+xml;utf-8,")
    end
  end

  describe "MFA challenge request body" do
    it "includes channel parameter" do
      setup_session(client, mock_session)
      allow(client).to receive(:_request).and_return({
        "id" => "challenge-id",
        "type" => "phone",
        "expires_at" => Time.now.to_i + 300
      })

      client.mfa.challenge(factor_id: "factor-123", channel: "whatsapp")

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("factors/factor-123/challenge")
        expect(kwargs[:body][:channel]).to eq("whatsapp")
      end
    end
  end

  describe "Admin delete_user request body" do
    it "passes should_soft_delete in body" do
      admin = Supabase::Auth::AdminApi.new(
        url: "http://localhost:9998",
        headers: { "Authorization" => "Bearer test-jwt" }
      )
      allow(admin).to receive(:_request).and_return({})

      uid = SecureRandom.uuid
      admin.delete_user(uid, should_soft_delete: true)

      expect(admin).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("DELETE")
        expect(path).to eq("admin/users/#{uid}")
        expect(kwargs[:body]).to eq({ should_soft_delete: true })
      end
    end
  end

  describe "#_remove_session clears @current_session" do
    it "clears @current_session when persist_session is true" do
      persist_client = Supabase::Auth::Client.new(
        url: "http://localhost:9998",
        auto_refresh_token: false,
        persist_session: true
      )
      setup_session(persist_client, mock_session)
      expect(persist_client.instance_variable_get(:@current_session)).not_to be_nil

      persist_client._remove_session

      expect(persist_client.instance_variable_get(:@current_session)).to be_nil
    end

    it "clears @current_session when persist_session is false" do
      setup_session(client, mock_session)
      expect(client.instance_variable_get(:@current_session)).not_to be_nil

      client._remove_session

      expect(client.instance_variable_get(:@current_session)).to be_nil
    end
  end

  describe "#_get_session_from_url validations" do
    it "raises error when access_token is missing" do
      url = "http://example.com/?refresh_token=abc&expires_in=3600&token_type=bearer"
      expect {
        client.send(:_get_session_from_url, url)
      }.to raise_error(Supabase::Auth::Errors::AuthImplicitGrantRedirectError, /No access_token detected/)
    end

    it "raises error when refresh_token is missing" do
      url = "http://example.com/?access_token=abc&expires_in=3600&token_type=bearer"
      expect {
        client.send(:_get_session_from_url, url)
      }.to raise_error(Supabase::Auth::Errors::AuthImplicitGrantRedirectError, /No refresh_token detected/)
    end

    it "raises error when expires_in is missing" do
      url = "http://example.com/?access_token=abc&refresh_token=def&token_type=bearer"
      expect {
        client.send(:_get_session_from_url, url)
      }.to raise_error(Supabase::Auth::Errors::AuthImplicitGrantRedirectError, /No expires_in detected/)
    end

    it "raises error when token_type is missing" do
      url = "http://example.com/?access_token=abc&refresh_token=def&expires_in=3600"
      expect {
        client.send(:_get_session_from_url, url)
      }.to raise_error(Supabase::Auth::Errors::AuthImplicitGrantRedirectError, /No token_type detected/)
    end

    it "extracts provider_token and provider_refresh_token" do
      allow(client).to receive(:get_user).and_return(
        Supabase::Auth::Types::UserResponse.new(user: mock_user)
      )

      url = "http://example.com/?access_token=abc&refresh_token=def&expires_in=3600&token_type=bearer&provider_token=prov-tok&provider_refresh_token=prov-refresh"
      session, _type = client.send(:_get_session_from_url, url)

      expect(session.provider_token).to eq("prov-tok")
      expect(session.provider_refresh_token).to eq("prov-refresh")
    end
  end

  describe "#_get_url_for_provider" do
    it "dynamically determines code_challenge_method" do
      client._flow_type = "pkce"
      url, params = client._get_url_for_provider("http://example.com/authorize", "github", {})

      # PKCE challenge should produce s256 (since SHA256 hash != verifier)
      expect(params["code_challenge_method"]).to eq("s256")
      expect(params["code_challenge"]).not_to be_nil
      expect(params["provider"]).to eq("github")
      expect(url).to include("provider=github")
    end

    it "passes through external params" do
      client._flow_type = "implicit"
      url, params = client._get_url_for_provider(
        "http://example.com/authorize", "google",
        { "redirect_to" => "https://app.example.com", "scopes" => "email" }
      )

      expect(params["redirect_to"]).to eq("https://app.example.com")
      expect(params["scopes"]).to eq("email")
      expect(params["provider"]).to eq("google")
      expect(url).to include("redirect_to=")
      expect(url).to include("scopes=email")
    end
  end

  describe "#_get_valid_session strict validation" do
    it "returns nil when access_token is missing" do
      raw = '{"refresh_token":"abc","expires_at":9999999999}'
      result = client.send(:_get_valid_session, raw)
      expect(result).to be_nil
    end

    it "returns nil when refresh_token is missing" do
      raw = '{"access_token":"abc","expires_at":9999999999}'
      result = client.send(:_get_valid_session, raw)
      expect(result).to be_nil
    end

    it "returns nil when expires_at is missing" do
      raw = '{"access_token":"abc","refresh_token":"def"}'
      result = client.send(:_get_valid_session, raw)
      expect(result).to be_nil
    end

    it "returns nil when expires_at is not a valid integer" do
      raw = '{"access_token":"abc","refresh_token":"def","expires_at":"not-a-number"}'
      result = client.send(:_get_valid_session, raw)
      expect(result).to be_nil
    end

    it "returns session when all required fields present" do
      raw = '{"access_token":"abc","refresh_token":"def","expires_at":9999999999,"token_type":"bearer"}'
      result = client.send(:_get_valid_session, raw)
      expect(result).not_to be_nil
      expect(result.access_token).to eq("abc")
    end
  end

  describe "#_recover_and_refresh SIGNED_IN notification" do
    it "emits SIGNED_IN when session is valid and not expired" do
      persist_client = Supabase::Auth::Client.new(
        url: "http://localhost:9998",
        auto_refresh_token: false,
        persist_session: true
      )

      # Store a valid, non-expired session
      valid_session_data = {
        access_token: "test-token",
        refresh_token: "test-refresh",
        token_type: "bearer",
        expires_in: 3600,
        expires_at: Time.now.to_i + 3600
      }
      persist_client._storage.set_item(persist_client._storage_key, JSON.generate(valid_session_data))

      events = []
      persist_client.on_auth_state_change { |event, _session| events << event }

      persist_client._recover_and_refresh

      expect(events).to include("SIGNED_IN")
    end
  end
end
