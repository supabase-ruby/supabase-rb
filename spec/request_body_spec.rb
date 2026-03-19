# frozen_string_literal: true

require "spec_helper"
require "jwt"
require "securerandom"

# These tests verify that the Ruby client sends the correct request bodies,
# matching the Python reference implementation.
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

    it "handles email OTP verification (email + token + type)" do
      allow(client).to receive(:_request).and_return(mock_auth_data)

      client.verify_otp(
        type: "email",
        email: "test@example.com",
        token: "123456"
      )

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("verify")
        expect(kwargs[:body][:type]).to eq("email")
        expect(kwargs[:body][:email]).to eq("test@example.com")
        expect(kwargs[:body][:token]).to eq("123456")
        expect(kwargs[:body]).not_to have_key(:phone)
        expect(kwargs[:body]).not_to have_key(:token_hash)
      end
    end

    it "handles token_hash verification without including token key (matching Python **params spread)" do
      allow(client).to receive(:_request).and_return(mock_auth_data)

      client.verify_otp(
        type: "email",
        token_hash: "abc123hash",
        options: { redirect_to: "https://example.com/confirm" }
      )

      expect(client).to have_received(:_request) do |_method, _path, **kwargs|
        expect(kwargs[:body][:type]).to eq("email")
        expect(kwargs[:body][:token_hash]).to eq("abc123hash")
        # Python: **params spread only includes keys present in the dict
        # token should NOT be in body when only token_hash is provided
        expect(kwargs[:body]).not_to have_key(:token)
        expect(kwargs[:redirect_to]).to eq("https://example.com/confirm")
      end
    end

    it "handles phone_change OTP type" do
      allow(client).to receive(:_request).and_return(mock_auth_data)

      client.verify_otp(
        type: "phone_change",
        phone: "+1234567890",
        token: "654321"
      )

      expect(client).to have_received(:_request) do |_method, _path, **kwargs|
        expect(kwargs[:body][:type]).to eq("phone_change")
        expect(kwargs[:body][:phone]).to eq("+1234567890")
        expect(kwargs[:body][:token]).to eq("654321")
      end
    end

    it "passes captcha_token in gotrue_meta_security and redirect_to separately" do
      allow(client).to receive(:_request).and_return(mock_auth_data)

      client.verify_otp(
        type: "sms",
        phone: "+1234567890",
        token: "123456",
        options: { captcha_token: "cap-tok", redirect_to: "https://app.com/cb" }
      )

      expect(client).to have_received(:_request) do |_method, _path, **kwargs|
        expect(kwargs[:body][:gotrue_meta_security]).to eq({ captcha_token: "cap-tok" })
        expect(kwargs[:redirect_to]).to eq("https://app.com/cb")
        # captcha_token should NOT be a top-level body key
        expect(kwargs[:body]).not_to have_key(:captcha_token)
      end
    end

    it "saves session and notifies subscribers when response has session" do
      allow(client).to receive(:_request).and_return(mock_auth_data)
      allow(client).to receive(:_save_session).and_call_original
      allow(client).to receive(:_notify_all_subscribers).and_call_original

      response = client.verify_otp(
        type: "sms",
        phone: "+1234567890",
        token: "123456"
      )

      expect(response).to be_a(Supabase::Auth::Types::AuthResponse)
      expect(response.session).not_to be_nil
      expect(client).to have_received(:_save_session)
      expect(client).to have_received(:_notify_all_subscribers).with("SIGNED_IN", anything)
    end

    it "does not save session when response has no session (e.g. email confirmation)" do
      allow(client).to receive(:_request).and_return({ "user" => nil })
      allow(client).to receive(:_save_session)

      response = client.verify_otp(
        type: "email",
        token_hash: "abc123",
      )

      expect(response.session).to be_nil
      expect(client).not_to have_received(:_save_session)
    end

    it "defaults captcha_token to nil when no options provided (matching Python)" do
      allow(client).to receive(:_request).and_return(mock_auth_data)

      client.verify_otp(type: "sms", phone: "+1234567890", token: "123456")

      expect(client).to have_received(:_request) do |_method, _path, **kwargs|
        expect(kwargs[:body][:gotrue_meta_security]).to eq({ captcha_token: nil })
        expect(kwargs[:redirect_to]).to be_nil
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

    %w[signup email_change sms phone_change].each do |resend_type|
      it "supports resend type: #{resend_type}" do
        allow(client).to receive(:_request).and_return({ "message_id" => "msg-id" })

        credential = if %w[signup email_change].include?(resend_type)
                       { email: "test@example.com", type: resend_type }
                     else
                       { phone: "+1234567890", type: resend_type }
                     end

        client.resend(credential)

        expect(client).to have_received(:_request) do |_method, _path, **kwargs|
          expect(kwargs[:body][:type]).to eq(resend_type)
        end
      end
    end

    it "raises AuthInvalidCredentialsError when neither email nor phone provided" do
      expect {
        client.resend(type: "signup")
      }.to raise_error(Supabase::Auth::Errors::AuthInvalidCredentialsError)
    end

    it "returns AuthOtpResponse" do
      allow(client).to receive(:_request).and_return({ "message_id" => "msg-id" })

      response = client.resend(email: "test@example.com", type: "signup")

      expect(response).to be_a(Supabase::Auth::Types::AuthOtpResponse)
    end

    it "email takes priority over phone when both provided (matching Python)" do
      allow(client).to receive(:_request).and_return({ "message_id" => "msg-id" })

      client.resend(
        email: "test@example.com",
        phone: "+1234567890",
        type: "signup"
      )

      expect(client).to have_received(:_request) do |_method, _path, **kwargs|
        expect(kwargs[:body][:email]).to eq("test@example.com")
        expect(kwargs[:body]).not_to have_key(:phone)
        # redirect_to should be passed since email takes priority
        expect(kwargs[:redirect_to]).to be_nil # nil because no email_redirect_to in options
      end
    end

    it "defaults captcha_token to nil when no options provided" do
      allow(client).to receive(:_request).and_return({ "message_id" => "msg-id" })

      client.resend(email: "test@example.com", type: "signup")

      expect(client).to have_received(:_request) do |_method, _path, **kwargs|
        expect(kwargs[:body][:gotrue_meta_security]).to eq({ captcha_token: nil })
      end
    end

    it "sends phone resend body with gotrue_meta_security" do
      allow(client).to receive(:_request).and_return({ "message_id" => "msg-id" })

      client.resend(
        phone: "+1234567890",
        type: "phone_change",
        options: { captcha_token: "cap-phone" }
      )

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("resend")
        expect(kwargs[:body][:phone]).to eq("+1234567890")
        expect(kwargs[:body][:type]).to eq("phone_change")
        expect(kwargs[:body][:gotrue_meta_security]).to eq({ captcha_token: "cap-phone" })
        expect(kwargs[:body]).not_to have_key(:email)
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

      expect(response).to be_a(Supabase::Auth::Types::LinkIdentityResponse)
      expect(response.url).to eq("https://provider.com/auth")
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

  # ==========================================
  # US-002: Session Management Methods Audit
  # ==========================================

  describe "#get_session (US-002)" do
    it "returns nil when no session exists" do
      result = client.get_session
      expect(result).to be_nil
    end

    it "returns session from @current_session when not persisting" do
      setup_session(client, mock_session)
      result = client.get_session
      expect(result).to eq(mock_session)
    end

    it "auto-refreshes when within EXPIRY_MARGIN (10 seconds)" do
      expired_session = Supabase::Auth::Types::Session.new(
        access_token: "expired-token",
        refresh_token: "valid-refresh",
        expires_in: 0,
        expires_at: Time.now.to_i + 5, # within 10-second margin
        token_type: "bearer",
        user: mock_user
      )
      setup_session(client, expired_session)

      # Mock _call_refresh_token to return a new session
      refreshed_session = Supabase::Auth::Types::Session.new(
        access_token: "new-token",
        refresh_token: "new-refresh",
        expires_in: 3600,
        expires_at: Time.now.to_i + 3600,
        token_type: "bearer",
        user: mock_user
      )
      allow(client).to receive(:_call_refresh_token).and_return(refreshed_session)

      result = client.get_session
      expect(result).to eq(refreshed_session)
      expect(client).to have_received(:_call_refresh_token).with("valid-refresh")
    end

    it "does NOT refresh when session is not within EXPIRY_MARGIN" do
      valid_session = Supabase::Auth::Types::Session.new(
        access_token: "valid-token",
        refresh_token: "valid-refresh",
        expires_in: 3600,
        expires_at: Time.now.to_i + 3600, # well beyond 10-second margin
        token_type: "bearer",
        user: mock_user
      )
      setup_session(client, valid_session)

      result = client.get_session
      expect(result).to eq(valid_session)
    end

    it "reads from storage when persist_session is true" do
      persist_client = Supabase::Auth::Client.new(
        url: "http://localhost:9998",
        auto_refresh_token: false,
        persist_session: true
      )
      session_data = {
        access_token: "stored-token",
        refresh_token: "stored-refresh",
        token_type: "bearer",
        expires_in: 3600,
        expires_at: Time.now.to_i + 3600
      }
      persist_client._storage.set_item(persist_client._storage_key, JSON.generate(session_data))

      result = persist_client.get_session
      expect(result).not_to be_nil
      expect(result.access_token).to eq("stored-token")
    end

    it "removes session from storage when invalid (matching Python)" do
      persist_client = Supabase::Auth::Client.new(
        url: "http://localhost:9998",
        auto_refresh_token: false,
        persist_session: true
      )
      persist_client._storage.set_item(persist_client._storage_key, '{"invalid":"data"}')

      result = persist_client.get_session
      expect(result).to be_nil
      expect(persist_client._storage.get_item(persist_client._storage_key)).to be_nil
    end

    it "treats has_expired as false when expires_at is nil (matching Python)" do
      no_expiry_session = Supabase::Auth::Types::Session.new(
        access_token: "token",
        refresh_token: "refresh",
        expires_in: nil,
        expires_at: nil,
        token_type: "bearer",
        user: mock_user
      )
      setup_session(client, no_expiry_session)

      result = client.get_session
      expect(result).to eq(no_expiry_session)
    end
  end

  describe "#set_session (US-002)" do
    it "refreshes when token is expired and refresh_token is provided" do
      # Create an expired JWT
      expired_payload = { "exp" => Time.now.to_i - 100, "sub" => "user-id" }
      expired_jwt = JWT.encode(expired_payload, "secret", "HS256")

      refreshed_data = mock_auth_data
      allow(client).to receive(:_request).and_return(refreshed_data)

      events = []
      client.on_auth_state_change { |event, _s| events << event }

      response = client.set_session(expired_jwt, "valid-refresh-token")

      expect(response).to be_a(Supabase::Auth::Types::AuthResponse)
      expect(response.session).not_to be_nil
      expect(events).to include("TOKEN_REFRESHED")
    end

    it "raises AuthSessionMissing when expired and no refresh_token" do
      expired_payload = { "exp" => Time.now.to_i - 100 }
      expired_jwt = JWT.encode(expired_payload, "secret", "HS256")

      expect {
        client.set_session(expired_jwt, nil)
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end

    it "raises AuthSessionMissing when expired and empty refresh_token" do
      expired_payload = { "exp" => Time.now.to_i - 100 }
      expired_jwt = JWT.encode(expired_payload, "secret", "HS256")

      expect {
        client.set_session(expired_jwt, "")
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end

    it "builds session from get_user when token is NOT expired" do
      future_exp = Time.now.to_i + 3600
      valid_payload = { "exp" => future_exp, "sub" => "user-id" }
      valid_jwt = JWT.encode(valid_payload, "secret", "HS256")

      allow(client).to receive(:get_user).and_return(
        Supabase::Auth::Types::UserResponse.new(user: mock_user)
      )

      events = []
      client.on_auth_state_change { |event, _s| events << event }

      response = client.set_session(valid_jwt, "refresh-token")

      expect(response.session.access_token).to eq(valid_jwt)
      expect(response.session.refresh_token).to eq("refresh-token")
      expect(response.session.token_type).to eq("bearer")
      expect(response.session.expires_at).to eq(future_exp)
      expect(response.user).to eq(mock_user)
      expect(events).to include("TOKEN_REFRESHED")
    end

    it "notifies TOKEN_REFRESHED (not SIGNED_IN), matching Python" do
      future_exp = Time.now.to_i + 3600
      valid_jwt = JWT.encode({ "exp" => future_exp }, "secret", "HS256")
      allow(client).to receive(:get_user).and_return(
        Supabase::Auth::Types::UserResponse.new(user: mock_user)
      )

      events = []
      client.on_auth_state_change { |event, _s| events << event }

      client.set_session(valid_jwt, "refresh")
      expect(events).to eq(["TOKEN_REFRESHED"])
    end
  end

  describe "#refresh_session (US-002)" do
    it "sends grant_type=refresh_token to /token endpoint" do
      allow(client).to receive(:_request).and_return(mock_auth_data)

      response = client.refresh_session("test-refresh-token")

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("token")
        expect(kwargs[:params]).to eq({ "grant_type" => "refresh_token" })
        expect(kwargs[:body]).to eq({ refresh_token: "test-refresh-token" })
      end
      expect(response).to be_a(Supabase::Auth::Types::AuthResponse)
      expect(response.session).not_to be_nil
    end

    it "uses current session's refresh_token when none provided" do
      setup_session(client, mock_session)
      allow(client).to receive(:_request).and_return(mock_auth_data)

      response = client.refresh_session

      expect(client).to have_received(:_request) do |_method, _path, **kwargs|
        expect(kwargs[:body]).to eq({ refresh_token: "mock-refresh-token" })
      end
      expect(response.session).not_to be_nil
    end

    it "raises AuthSessionMissing when no refresh_token available" do
      expect {
        client.refresh_session
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end
  end

  describe "#sign_out scopes (US-002)" do
    it "defaults scope to 'global' (matching Python)" do
      setup_session(client, mock_session)
      allow(client.admin).to receive(:sign_out)

      events = []
      client.on_auth_state_change { |event, _s| events << event }

      client.sign_out

      expect(client.admin).to have_received(:sign_out).with("mock-access-token", "global")
      expect(events).to include("SIGNED_OUT")
    end

    it "removes session and notifies for scope 'local'" do
      setup_session(client, mock_session)
      allow(client.admin).to receive(:sign_out)

      events = []
      client.on_auth_state_change { |event, _s| events << event }

      client.sign_out(scope: "local")

      expect(client.admin).to have_received(:sign_out).with("mock-access-token", "local")
      expect(events).to include("SIGNED_OUT")
      expect(client.instance_variable_get(:@current_session)).to be_nil
    end

    it "does NOT remove session for scope 'others'" do
      setup_session(client, mock_session)
      allow(client.admin).to receive(:sign_out)

      events = []
      client.on_auth_state_change { |event, _s| events << event }

      client.sign_out(scope: "others")

      expect(client.admin).to have_received(:sign_out).with("mock-access-token", "others")
      expect(events).not_to include("SIGNED_OUT")
      expect(client.instance_variable_get(:@current_session)).not_to be_nil
    end

    it "suppresses AuthApiError from admin.sign_out (matching Python)" do
      setup_session(client, mock_session)
      allow(client.admin).to receive(:sign_out).and_raise(
        Supabase::Auth::Errors::AuthApiError.new("token expired", status: 401)
      )

      events = []
      client.on_auth_state_change { |event, _s| events << event }

      expect { client.sign_out }.not_to raise_error
      expect(events).to include("SIGNED_OUT")
    end

    it "handles sign_out when no session exists" do
      events = []
      client.on_auth_state_change { |event, _s| events << event }

      expect { client.sign_out }.not_to raise_error
      expect(events).to include("SIGNED_OUT")
    end
  end

  describe "#exchange_code_for_session (US-002)" do
    it "sends auth_code and code_verifier with grant_type=pkce" do
      allow(client).to receive(:_request).and_return(mock_auth_data)

      response = client.exchange_code_for_session(
        auth_code: "auth-code-123",
        code_verifier: "verifier-abc"
      )

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("token")
        expect(kwargs[:params]).to eq({ "grant_type" => "pkce" })
        expect(kwargs[:body][:auth_code]).to eq("auth-code-123")
        expect(kwargs[:body][:code_verifier]).to eq("verifier-abc")
      end
      expect(response.session).not_to be_nil
    end

    it "reads code_verifier from storage when not provided" do
      client._storage.set_item("#{client._storage_key}-code-verifier", "stored-verifier")
      allow(client).to receive(:_request).and_return(mock_auth_data)

      client.exchange_code_for_session(auth_code: "auth-code-123")

      expect(client).to have_received(:_request) do |_method, _path, **kwargs|
        expect(kwargs[:body][:code_verifier]).to eq("stored-verifier")
      end
    end

    it "cleans up code_verifier from storage after exchange" do
      client._storage.set_item("#{client._storage_key}-code-verifier", "stored-verifier")
      allow(client).to receive(:_request).and_return(mock_auth_data)

      client.exchange_code_for_session(auth_code: "auth-code-123")

      expect(client._storage.get_item("#{client._storage_key}-code-verifier")).to be_nil
    end

    it "saves session and notifies SIGNED_IN on success" do
      allow(client).to receive(:_request).and_return(mock_auth_data)

      events = []
      client.on_auth_state_change { |event, _s| events << event }

      response = client.exchange_code_for_session(
        auth_code: "auth-code-123",
        code_verifier: "verifier-abc"
      )

      expect(response.session).not_to be_nil
      expect(events).to include("SIGNED_IN")
    end

    it "passes redirect_to parameter" do
      allow(client).to receive(:_request).and_return(mock_auth_data)

      client.exchange_code_for_session(
        auth_code: "auth-code-123",
        code_verifier: "verifier-abc",
        redirect_to: "https://app.example.com"
      )

      expect(client).to have_received(:_request) do |_method, _path, **kwargs|
        expect(kwargs[:redirect_to]).to eq("https://app.example.com")
      end
    end
  end

  describe "Auto-refresh token (US-002)" do
    it "_start_auto_refresh_token cancels existing timer before creating new one" do
      timer_mock = instance_double(Supabase::Auth::Timer, start: nil, cancel: nil, alive?: true)
      allow(Supabase::Auth::Timer).to receive(:new).and_return(timer_mock)

      auto_client = Supabase::Auth::Client.new(
        url: "http://localhost:9998",
        auto_refresh_token: true,
        persist_session: false
      )

      # Set up an existing timer
      auto_client.instance_variable_set(:@refresh_token_timer, timer_mock)

      auto_client._start_auto_refresh_token(60_000)

      expect(timer_mock).to have_received(:cancel)
    end

    it "_start_auto_refresh_token does nothing when value <= 0" do
      auto_client = Supabase::Auth::Client.new(
        url: "http://localhost:9998",
        auto_refresh_token: true,
        persist_session: false
      )

      result = auto_client._start_auto_refresh_token(0)
      expect(result).to be_nil
      expect(auto_client.instance_variable_get(:@refresh_token_timer)).to be_nil
    end

    it "_start_auto_refresh_token does nothing when auto_refresh_token is false" do
      result = client._start_auto_refresh_token(60_000)
      expect(result).to be_nil
      expect(client.instance_variable_get(:@refresh_token_timer)).to be_nil
    end

    it "MAX_RETRIES is 10 (matching Python)" do
      expect(Supabase::Auth::Constants::MAX_RETRIES).to eq(10)
    end

    it "RETRY_INTERVAL is 2 (matching Python)" do
      expect(Supabase::Auth::Constants::RETRY_INTERVAL).to eq(2)
    end

    it "EXPIRY_MARGIN is 10 (matching Python)" do
      expect(Supabase::Auth::Client::EXPIRY_MARGIN).to eq(10)
    end
  end

  describe "#_save_session scheduling (US-002)" do
    it "schedules auto-refresh when session has expires_at" do
      auto_client = Supabase::Auth::Client.new(
        url: "http://localhost:9998",
        auto_refresh_token: true,
        persist_session: false
      )
      allow(auto_client).to receive(:_start_auto_refresh_token)

      auto_client.send(:_save_session, mock_session)

      expect(auto_client).to have_received(:_start_auto_refresh_token).with(kind_of(Numeric))
    end

    it "stores session in storage when persist_session is true" do
      persist_client = Supabase::Auth::Client.new(
        url: "http://localhost:9998",
        auto_refresh_token: false,
        persist_session: true
      )

      persist_client.send(:_save_session, mock_session)

      stored = persist_client._storage.get_item(persist_client._storage_key)
      expect(stored).not_to be_nil
      parsed = JSON.parse(stored)
      expect(parsed["access_token"]).to eq("mock-access-token")
      expect(parsed["refresh_token"]).to eq("mock-refresh-token")
    end

    it "calculates refresh_duration_before_expires matching Python" do
      auto_client = Supabase::Auth::Client.new(
        url: "http://localhost:9998",
        auto_refresh_token: true,
        persist_session: false
      )
      allow(auto_client).to receive(:_start_auto_refresh_token)

      # Session with expire_in > EXPIRY_MARGIN (10)
      session_with_long_expiry = Supabase::Auth::Types::Session.new(
        access_token: "token",
        refresh_token: "refresh",
        expires_in: 3600,
        expires_at: Time.now.to_i + 3600,
        token_type: "bearer",
        user: mock_user
      )
      auto_client.send(:_save_session, session_with_long_expiry)

      expect(auto_client).to have_received(:_start_auto_refresh_token) do |value|
        # value = (expire_in - EXPIRY_MARGIN) * 1000
        # expire_in ≈ 3600, so value ≈ 3590000
        expect(value).to be > 3_500_000
        expect(value).to be < 3_700_000
      end
    end

    it "uses 0.5s margin when expire_in <= EXPIRY_MARGIN (matching Python)" do
      auto_client = Supabase::Auth::Client.new(
        url: "http://localhost:9998",
        auto_refresh_token: true,
        persist_session: false
      )
      allow(auto_client).to receive(:_start_auto_refresh_token)

      # Session expiring in 5 seconds (within EXPIRY_MARGIN)
      session_soon_expiry = Supabase::Auth::Types::Session.new(
        access_token: "token",
        refresh_token: "refresh",
        expires_in: 5,
        expires_at: Time.now.to_i + 5,
        token_type: "bearer",
        user: mock_user
      )
      auto_client.send(:_save_session, session_soon_expiry)

      expect(auto_client).to have_received(:_start_auto_refresh_token) do |value|
        # value = (expire_in - 0.5) * 1000
        # expire_in ≈ 5, so value ≈ 4500
        expect(value).to be > 3_000
        expect(value).to be < 6_000
      end
    end
  end

  describe "#_recover_and_refresh (US-002)" do
    it "removes session from storage when raw_session is invalid" do
      persist_client = Supabase::Auth::Client.new(
        url: "http://localhost:9998",
        auto_refresh_token: false,
        persist_session: true
      )
      persist_client._storage.set_item(persist_client._storage_key, "not-json")

      persist_client._recover_and_refresh

      expect(persist_client._storage.get_item(persist_client._storage_key)).to be_nil
    end

    it "does nothing when storage is empty" do
      persist_client = Supabase::Auth::Client.new(
        url: "http://localhost:9998",
        auto_refresh_token: false,
        persist_session: true
      )

      events = []
      persist_client.on_auth_state_change { |event, _s| events << event }

      persist_client._recover_and_refresh

      expect(events).to be_empty
    end

    it "refreshes expired session with auto_refresh_token" do
      persist_client = Supabase::Auth::Client.new(
        url: "http://localhost:9998",
        auto_refresh_token: true,
        persist_session: true
      )
      expired_data = {
        access_token: "expired",
        refresh_token: "valid-refresh",
        token_type: "bearer",
        expires_in: 0,
        expires_at: Time.now.to_i - 100
      }
      persist_client._storage.set_item(persist_client._storage_key, JSON.generate(expired_data))

      allow(persist_client).to receive(:_call_refresh_token).and_return(mock_session)

      events = []
      persist_client.on_auth_state_change { |event, _s| events << event }

      persist_client._recover_and_refresh

      expect(persist_client).to have_received(:_call_refresh_token).with("valid-refresh")
    end
  end

  describe "#_call_refresh_token (US-002)" do
    it "raises AuthSessionMissing for nil refresh_token" do
      expect {
        client._call_refresh_token(nil)
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end

    it "raises AuthSessionMissing for empty refresh_token" do
      expect {
        client._call_refresh_token("")
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end

    it "saves session and notifies TOKEN_REFRESHED on success" do
      allow(client).to receive(:_request).and_return(mock_auth_data)

      events = []
      client.on_auth_state_change { |event, _s| events << event }

      result = client._call_refresh_token("valid-refresh")

      expect(result).to be_a(Supabase::Auth::Types::Session)
      expect(events).to include("TOKEN_REFRESHED")
    end

    it "raises AuthSessionMissing when response has no session" do
      allow(client).to receive(:_request).and_return({})

      expect {
        client._call_refresh_token("valid-refresh")
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end
  end

  # ─── US-003: User Management Methods Audit ───────────────────────────────────

  describe "get_user" do
    it "sends GET /user with session access_token when no JWT provided" do
      allow(client).to receive(:get_session).and_return(mock_session)
      allow(client).to receive(:_request).and_return({"user" => {"id" => "u1", "aud" => "", "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z", "app_metadata" => {}, "user_metadata" => {}}})

      client.get_user

      expect(client).to have_received(:_request).with("GET", "user", hash_including(jwt: "mock-access-token"))
    end

    it "sends GET /user with provided JWT instead of session token" do
      allow(client).to receive(:_request).and_return({"user" => {"id" => "u1", "aud" => "", "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z", "app_metadata" => {}, "user_metadata" => {}}})

      client.get_user("custom-jwt-token")

      expect(client).to have_received(:_request).with("GET", "user", hash_including(jwt: "custom-jwt-token"))
    end

    it "returns nil when no session and no JWT provided" do
      allow(client).to receive(:get_session).and_return(nil)

      result = client.get_user
      expect(result).to be_nil
    end

    it "returns UserResponse with parsed user data" do
      allow(client).to receive(:get_session).and_return(mock_session)
      allow(client).to receive(:_request).and_return({"user" => {"id" => "u1", "aud" => "test", "email" => "a@b.com", "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z", "app_metadata" => {}, "user_metadata" => {}}})

      result = client.get_user
      expect(result).to be_a(Supabase::Auth::Types::UserResponse)
      expect(result.user.id).to eq("u1")
    end

    it "does not check session when JWT is explicitly provided (matching Python)" do
      allow(client).to receive(:_request).and_return({"user" => {"id" => "u1", "aud" => "", "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z", "app_metadata" => {}, "user_metadata" => {}}})

      # Should NOT call get_session when jwt is provided
      expect(client).not_to receive(:get_session)
      client.get_user("explicit-jwt")
    end
  end

  describe "update_user" do
    it "sends PUT /user with attributes body and session JWT" do
      allow(client).to receive(:get_session).and_return(mock_session)
      allow(client).to receive(:_request).and_return({"user" => {"id" => "u1", "aud" => "", "email" => "new@test.com", "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z", "app_metadata" => {}, "user_metadata" => {}}})
      allow(client).to receive(:_save_session)
      allow(client).to receive(:_notify_all_subscribers)

      attributes = {email: "new@test.com"}
      client.update_user(attributes)

      expect(client).to have_received(:_request).with("PUT", "user", hash_including(
        jwt: "mock-access-token",
        body: {email: "new@test.com"}
      ))
    end

    it "passes email_redirect_to as redirect_to parameter" do
      allow(client).to receive(:get_session).and_return(mock_session)
      allow(client).to receive(:_request).and_return({"user" => {"id" => "u1", "aud" => "", "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z", "app_metadata" => {}, "user_metadata" => {}}})
      allow(client).to receive(:_save_session)
      allow(client).to receive(:_notify_all_subscribers)

      client.update_user({email: "x@y.com"}, {email_redirect_to: "https://example.com/confirm"})

      expect(client).to have_received(:_request).with("PUT", "user", hash_including(
        redirect_to: "https://example.com/confirm"
      ))
    end

    it "raises AuthSessionMissing when no session" do
      allow(client).to receive(:get_session).and_return(nil)

      expect {
        client.update_user({email: "x@y.com"})
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end

    it "updates session user and notifies USER_UPDATED" do
      allow(client).to receive(:get_session).and_return(mock_session)
      allow(client).to receive(:_request).and_return({"user" => {"id" => "u1", "aud" => "", "email" => "updated@test.com", "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z", "app_metadata" => {}, "user_metadata" => {}}})
      allow(client).to receive(:_save_session)
      allow(client).to receive(:_notify_all_subscribers)

      client.update_user({email: "updated@test.com"})

      expect(client).to have_received(:_save_session).with(an_object_having_attributes(
        access_token: "mock-access-token",
        refresh_token: "mock-refresh-token"
      ))
      expect(client).to have_received(:_notify_all_subscribers).with("USER_UPDATED", anything)
    end

    it "returns UserResponse with updated user" do
      allow(client).to receive(:get_session).and_return(mock_session)
      allow(client).to receive(:_request).and_return({"user" => {"id" => "u1", "aud" => "", "email" => "updated@test.com", "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z", "app_metadata" => {}, "user_metadata" => {}}})
      allow(client).to receive(:_save_session)
      allow(client).to receive(:_notify_all_subscribers)

      result = client.update_user({email: "updated@test.com"})
      expect(result).to be_a(Supabase::Auth::Types::UserResponse)
      expect(result.user.email).to eq("updated@test.com")
    end
  end

  describe "get_user_identities" do
    it "wraps get_user and returns IdentitiesResponse" do
      identity_data = {"identity_id" => "id1", "id" => "id1", "user_id" => "u1", "provider" => "google", "identity_data" => {}, "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z", "last_sign_in_at" => "2023-01-01T00:00:00Z"}
      allow(client).to receive(:get_session).and_return(mock_session)
      allow(client).to receive(:_request).and_return({"user" => {"id" => "u1", "aud" => "", "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z", "app_metadata" => {}, "user_metadata" => {}, "identities" => [identity_data]}})

      result = client.get_user_identities
      expect(result).to be_a(Supabase::Auth::Types::IdentitiesResponse)
      expect(result.identities.length).to eq(1)
    end

    it "raises AuthSessionMissing when no session" do
      allow(client).to receive(:get_session).and_return(nil)

      expect {
        client.get_user_identities
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end

    it "returns empty identities when user has none" do
      allow(client).to receive(:get_session).and_return(mock_session)
      allow(client).to receive(:_request).and_return({"user" => {"id" => "u1", "aud" => "", "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z", "app_metadata" => {}, "user_metadata" => {}}})

      result = client.get_user_identities
      expect(result.identities).to eq([])
    end
  end

  describe "link_identity" do
    it "sends GET /user/identities/authorize with provider query params" do
      allow(client).to receive(:get_session).and_return(mock_session)
      allow(client).to receive(:_request).and_return(Supabase::Auth::Types::LinkIdentityResponse.new(url: "https://provider.com/auth"))

      client.link_identity(provider: "google", options: {redirect_to: "https://app.com/callback", scopes: "email profile"})

      expect(client).to have_received(:_request).with("GET", "user/identities/authorize", hash_including(
        jwt: "mock-access-token"
      ))
    end

    it "includes skip_http_redirect=true in params (matching Python)" do
      allow(client).to receive(:get_session).and_return(mock_session)
      call_args = nil
      allow(client).to receive(:_request) do |*args, **kwargs|
        call_args = kwargs
        Supabase::Auth::Types::LinkIdentityResponse.new(url: "https://provider.com/auth")
      end

      client.link_identity(provider: "github")

      expect(call_args[:params]).to include("skip_http_redirect" => "true")
    end

    it "raises AuthSessionMissing when no session" do
      allow(client).to receive(:get_session).and_return(nil)

      expect {
        client.link_identity(provider: "google")
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end

    it "returns LinkIdentityResponse with only url" do
      allow(client).to receive(:get_session).and_return(mock_session)
      allow(client).to receive(:_request).and_return(Supabase::Auth::Types::LinkIdentityResponse.new(url: "https://auth.example.com/link"))

      result = client.link_identity(provider: "google")
      expect(result).to be_a(Supabase::Auth::Types::LinkIdentityResponse)
      expect(result.url).to eq("https://auth.example.com/link")
    end
  end

  describe "unlink_identity" do
    it "sends DELETE /user/identities/{identity_id} with session JWT" do
      allow(client).to receive(:get_session).and_return(mock_session)
      allow(client).to receive(:_request).and_return(nil)

      identity = Supabase::Auth::Types::UserIdentity.new(identity_id: "id-123", id: "id-123", user_id: "u1", provider: "google", identity_data: {}, created_at: Time.now, updated_at: Time.now, last_sign_in_at: Time.now)
      client.unlink_identity(identity)

      expect(client).to have_received(:_request).with("DELETE", "user/identities/id-123", hash_including(jwt: "mock-access-token"))
    end

    it "accepts hash with identity_id key" do
      allow(client).to receive(:get_session).and_return(mock_session)
      allow(client).to receive(:_request).and_return(nil)

      client.unlink_identity({identity_id: "id-456"})

      expect(client).to have_received(:_request).with("DELETE", "user/identities/id-456", anything)
    end

    it "raises AuthSessionMissing when no session" do
      allow(client).to receive(:get_session).and_return(nil)

      expect {
        client.unlink_identity({identity_id: "id-123"})
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end
  end

  describe "reset_password_for_email" do
    it "sends POST /recover with email and captcha_token in body" do
      allow(client).to receive(:_request)

      client.reset_password_for_email("user@test.com", captcha_token: "cap-token-123")

      expect(client).to have_received(:_request).with("POST", "recover", hash_including(
        body: {
          email: "user@test.com",
          gotrue_meta_security: {captcha_token: "cap-token-123"}
        }
      ))
    end

    it "passes redirect_to as redirect_to parameter" do
      allow(client).to receive(:_request)

      client.reset_password_for_email("user@test.com", redirect_to: "https://app.com/reset")

      expect(client).to have_received(:_request).with("POST", "recover", hash_including(
        redirect_to: "https://app.com/reset"
      ))
    end

    it "does not require a session (public endpoint, matching Python)" do
      allow(client).to receive(:_request)

      # Should not call get_session
      expect(client).not_to receive(:get_session)
      client.reset_password_for_email("user@test.com")
    end

    it "sends nil captcha_token when not provided" do
      allow(client).to receive(:_request)

      client.reset_password_for_email("user@test.com")

      expect(client).to have_received(:_request).with("POST", "recover", hash_including(
        body: {
          email: "user@test.com",
          gotrue_meta_security: {captcha_token: nil}
        }
      ))
    end
  end

  describe "reauthenticate" do
    it "sends GET /reauthenticate with session JWT" do
      allow(client).to receive(:get_session).and_return(mock_session)
      allow(client).to receive(:_request).and_return({"access_token" => "t", "refresh_token" => "r", "expires_in" => 3600, "token_type" => "bearer", "user" => {"id" => "u1", "aud" => "", "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z", "app_metadata" => {}, "user_metadata" => {}}})

      client.reauthenticate

      expect(client).to have_received(:_request).with("GET", "reauthenticate", hash_including(jwt: "mock-access-token"))
    end

    it "raises AuthSessionMissing when no session" do
      allow(client).to receive(:get_session).and_return(nil)

      expect {
        client.reauthenticate
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end

    it "returns AuthResponse" do
      allow(client).to receive(:get_session).and_return(mock_session)
      allow(client).to receive(:_request).and_return({"access_token" => "t", "refresh_token" => "r", "expires_in" => 3600, "token_type" => "bearer", "user" => {"id" => "u1", "aud" => "", "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z", "app_metadata" => {}, "user_metadata" => {}}})

      result = client.reauthenticate
      expect(result).to be_a(Supabase::Auth::Types::AuthResponse)
    end
  end

  # ===== US-004: Admin API Method Audit =====
  # Verifies all AdminApi methods match Python's SyncGoTrueAdminAPI

  describe "AdminApi#create_user" do
    let(:admin) do
      Supabase::Auth::AdminApi.new(
        url: "http://localhost:9998",
        headers: { "Authorization" => "Bearer service-role-jwt" }
      )
    end

    it "sends POST to admin/users with AdminUserAttributes body" do
      allow(admin).to receive(:_request).and_return({ "id" => "u1", "aud" => "", "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z", "app_metadata" => {}, "user_metadata" => {} })

      admin.create_user(email: "new@test.com", password: "secret", user_metadata: { "name" => "Test" })

      expect(admin).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq(:post)
        expect(path).to eq("admin/users")
        expect(kwargs[:body]).to eq(email: "new@test.com", password: "secret", user_metadata: { "name" => "Test" })
      end
    end

    it "returns UserResponse" do
      allow(admin).to receive(:_request).and_return({ "id" => "u1", "aud" => "", "email" => "new@test.com", "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z", "app_metadata" => {}, "user_metadata" => {} })

      result = admin.create_user(email: "new@test.com", password: "secret")
      expect(result).to be_a(Supabase::Auth::Types::UserResponse)
      expect(result.user.email).to eq("new@test.com")
    end
  end

  describe "AdminApi#list_users" do
    let(:admin) do
      Supabase::Auth::AdminApi.new(
        url: "http://localhost:9998",
        headers: { "Authorization" => "Bearer service-role-jwt" }
      )
    end

    it "sends GET to admin/users with page/per_page query params" do
      allow(admin).to receive(:_request).and_return({ "users" => [] })

      admin.list_users(page: 2, per_page: 10)

      expect(admin).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq(:get)
        expect(path).to eq("admin/users")
        expect(kwargs[:params]).to eq(page: 2, per_page: 10)
      end
    end

    it "omits nil pagination params (matching Python httpx behavior)" do
      allow(admin).to receive(:_request).and_return({ "users" => [] })

      admin.list_users

      expect(admin).to have_received(:_request) do |method, path, **kwargs|
        expect(kwargs[:params]).to eq({})
      end
    end

    it "returns array of User objects" do
      allow(admin).to receive(:_request).and_return({
        "users" => [
          { "id" => "u1", "aud" => "", "email" => "a@test.com", "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z", "app_metadata" => {}, "user_metadata" => {} }
        ]
      })

      result = admin.list_users
      expect(result).to be_a(Array)
      expect(result.first).to be_a(Supabase::Auth::Types::User)
    end

    it "returns empty array when no users key" do
      allow(admin).to receive(:_request).and_return({})

      result = admin.list_users
      expect(result).to eq([])
    end
  end

  describe "AdminApi#get_user_by_id" do
    let(:admin) do
      Supabase::Auth::AdminApi.new(
        url: "http://localhost:9998",
        headers: { "Authorization" => "Bearer service-role-jwt" }
      )
    end

    it "validates UUID format before making request" do
      expect { admin.get_user_by_id("not-a-uuid") }.to raise_error(ArgumentError, /not a valid uuid/)
    end

    it "sends GET to admin/users/{uid}" do
      uid = SecureRandom.uuid
      allow(admin).to receive(:_request).and_return({ "id" => uid, "aud" => "", "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z", "app_metadata" => {}, "user_metadata" => {} })

      admin.get_user_by_id(uid)

      expect(admin).to have_received(:_request) do |method, path, **_kwargs|
        expect(method).to eq(:get)
        expect(path).to eq("admin/users/#{uid}")
      end
    end

    it "returns UserResponse" do
      uid = SecureRandom.uuid
      allow(admin).to receive(:_request).and_return({ "id" => uid, "aud" => "", "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z", "app_metadata" => {}, "user_metadata" => {} })

      result = admin.get_user_by_id(uid)
      expect(result).to be_a(Supabase::Auth::Types::UserResponse)
    end
  end

  describe "AdminApi#update_user_by_id" do
    let(:admin) do
      Supabase::Auth::AdminApi.new(
        url: "http://localhost:9998",
        headers: { "Authorization" => "Bearer service-role-jwt" }
      )
    end

    it "validates UUID and sends PUT to admin/users/{uid}" do
      uid = SecureRandom.uuid
      allow(admin).to receive(:_request).and_return({ "id" => uid, "aud" => "", "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z", "app_metadata" => {}, "user_metadata" => {} })

      admin.update_user_by_id(uid, email: "updated@test.com", user_metadata: { "key" => "val" })

      expect(admin).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq(:put)
        expect(path).to eq("admin/users/#{uid}")
        expect(kwargs[:body]).to eq(email: "updated@test.com", user_metadata: { "key" => "val" })
      end
    end

    it "raises ArgumentError for invalid UUID" do
      expect { admin.update_user_by_id("bad", email: "x@y.com") }.to raise_error(ArgumentError)
    end
  end

  describe "AdminApi#delete_user" do
    let(:admin) do
      Supabase::Auth::AdminApi.new(
        url: "http://localhost:9998",
        headers: { "Authorization" => "Bearer service-role-jwt" }
      )
    end

    it "sends DELETE to admin/users/{uid} with should_soft_delete body" do
      uid = SecureRandom.uuid
      allow(admin).to receive(:_request).and_return({})

      admin.delete_user(uid, should_soft_delete: true)

      expect(admin).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("DELETE")
        expect(path).to eq("admin/users/#{uid}")
        expect(kwargs[:body]).to eq({ should_soft_delete: true })
      end
    end

    it "defaults should_soft_delete to false" do
      uid = SecureRandom.uuid
      allow(admin).to receive(:_request).and_return({})

      admin.delete_user(uid)

      expect(admin).to have_received(:_request) do |method, _path, **kwargs|
        expect(kwargs[:body]).to eq({ should_soft_delete: false })
      end
    end

    it "validates UUID" do
      expect { admin.delete_user("invalid") }.to raise_error(ArgumentError)
    end
  end

  describe "AdminApi#invite_user_by_email" do
    let(:admin) do
      Supabase::Auth::AdminApi.new(
        url: "http://localhost:9998",
        headers: { "Authorization" => "Bearer service-role-jwt" }
      )
    end

    it "sends POST to invite with email, data body and redirect_to query param" do
      allow(admin).to receive(:_request).and_return({ "id" => "u1", "aud" => "", "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z", "app_metadata" => {}, "user_metadata" => {} })

      admin.invite_user_by_email("invite@test.com", data: { "role" => "admin" }, redirect_to: "https://app.com/welcome")

      expect(admin).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq(:post)
        expect(path).to eq("invite")
        expect(kwargs[:body][:email]).to eq("invite@test.com")
        expect(kwargs[:body][:data]).to eq({ "role" => "admin" })
        expect(kwargs[:params]).to eq({ "redirect_to" => "https://app.com/welcome" })
      end
    end

    it "sends nil data when no options provided (matching Python options.get('data') -> None)" do
      allow(admin).to receive(:_request).and_return({ "id" => "u1", "aud" => "", "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z", "app_metadata" => {}, "user_metadata" => {} })

      admin.invite_user_by_email("invite@test.com")

      expect(admin).to have_received(:_request) do |method, path, **kwargs|
        expect(kwargs[:body]).to eq({ email: "invite@test.com", data: nil })
        expect(kwargs[:params]).to eq({})
      end
    end

    it "returns UserResponse" do
      allow(admin).to receive(:_request).and_return({ "id" => "u1", "aud" => "", "email" => "invite@test.com", "invited_at" => "2023-01-01T00:00:00Z", "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z", "app_metadata" => {}, "user_metadata" => {} })

      result = admin.invite_user_by_email("invite@test.com")
      expect(result).to be_a(Supabase::Auth::Types::UserResponse)
    end
  end

  describe "AdminApi#generate_link" do
    let(:admin) do
      Supabase::Auth::AdminApi.new(
        url: "http://localhost:9998",
        headers: { "Authorization" => "Bearer service-role-jwt" }
      )
    end

    it "constructs body for signup link type with all fields" do
      allow(admin).to receive(:_request).and_return({
        "id" => "u1", "aud" => "", "email" => "t@t.com", "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z",
        "app_metadata" => {}, "user_metadata" => { "status" => "alpha" },
        "action_link" => "http://localhost:9998/verify?token=abc", "hashed_token" => "abc", "verification_type" => "signup", "redirect_to" => "http://app.com"
      })

      admin.generate_link(
        type: "signup",
        email: "t@t.com",
        password: "secret123",
        options: { data: { "status" => "alpha" }, redirect_to: "http://app.com" }
      )

      expect(admin).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq(:post)
        expect(path).to eq("admin/generate_link")
        body = kwargs[:body]
        expect(body[:type]).to eq("signup")
        expect(body[:email]).to eq("t@t.com")
        expect(body[:password]).to eq("secret123")
        expect(body[:data]).to eq({ "status" => "alpha" })
        # Python sends nil/None for new_email — Ruby must NOT compact it away
        expect(body).to have_key(:new_email)
        expect(body[:new_email]).to be_nil
      end
    end

    it "constructs body for email_change_current with new_email" do
      allow(admin).to receive(:_request).and_return({
        "id" => "u1", "aud" => "", "email" => "old@t.com", "new_email" => "new@t.com",
        "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z",
        "app_metadata" => {}, "user_metadata" => {},
        "action_link" => "http://localhost:9998/verify?token=abc", "hashed_token" => "abc", "verification_type" => "email_change_current", "redirect_to" => "http://app.com"
      })

      admin.generate_link(
        type: "email_change_current",
        email: "old@t.com",
        new_email: "new@t.com",
        options: { redirect_to: "http://app.com" }
      )

      expect(admin).to have_received(:_request) do |_method, _path, **kwargs|
        body = kwargs[:body]
        expect(body[:type]).to eq("email_change_current")
        expect(body[:new_email]).to eq("new@t.com")
        expect(body[:password]).to be_nil
        expect(body[:data]).to be_nil
      end
    end

    it "passes redirect_to as query param" do
      allow(admin).to receive(:_request).and_return({
        "id" => "u1", "aud" => "", "email" => "t@t.com", "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z",
        "app_metadata" => {}, "user_metadata" => {},
        "action_link" => "http://localhost:9998/verify?token=abc", "hashed_token" => "abc", "verification_type" => "signup", "redirect_to" => "http://app.com"
      })

      admin.generate_link(type: "signup", email: "t@t.com", password: "s", options: { redirect_to: "http://app.com" })

      expect(admin).to have_received(:_request) do |_method, _path, **kwargs|
        expect(kwargs[:params]).to eq({ "redirect_to" => "http://app.com" })
      end
    end

    it "returns GenerateLinkResponse" do
      allow(admin).to receive(:_request).and_return({
        "id" => "u1", "aud" => "", "email" => "t@t.com", "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z",
        "app_metadata" => {}, "user_metadata" => {},
        "action_link" => "http://localhost:9998/verify?token=abc", "hashed_token" => "abc", "verification_type" => "signup", "redirect_to" => "http://app.com"
      })

      result = admin.generate_link(type: "signup", email: "t@t.com", password: "s")
      expect(result).to be_a(Supabase::Auth::Types::GenerateLinkResponse)
    end
  end

  describe "AdminApi#sign_out" do
    let(:admin) do
      Supabase::Auth::AdminApi.new(
        url: "http://localhost:9998",
        headers: { "Authorization" => "Bearer service-role-jwt" }
      )
    end

    it "sends POST to logout with jwt parameter and scope as query param" do
      allow(admin).to receive(:_request).and_return(nil)

      admin.sign_out("user-access-token", "local")

      expect(admin).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("logout")
        expect(kwargs[:jwt]).to eq("user-access-token")
        expect(kwargs[:params]).to eq({ "scope" => "local" })
        expect(kwargs[:no_resolve_json]).to eq(true)
      end
    end

    it "defaults scope to global (matching Python SignOutScope default)" do
      allow(admin).to receive(:_request).and_return(nil)

      admin.sign_out("user-access-token")

      expect(admin).to have_received(:_request) do |_method, _path, **kwargs|
        expect(kwargs[:params]).to eq({ "scope" => "global" })
      end
    end

    it "does NOT send a body (matching Python — no body parameter)" do
      allow(admin).to receive(:_request).and_return(nil)

      admin.sign_out("tok")

      expect(admin).to have_received(:_request) do |_method, _path, **kwargs|
        expect(kwargs[:body]).to be_nil
      end
    end

    it "uses no_resolve_json: true (matching Python no_resolve_json=True)" do
      allow(admin).to receive(:_request).and_return(nil)

      admin.sign_out("tok")

      expect(admin).to have_received(:_request) do |_method, _path, **kwargs|
        expect(kwargs[:no_resolve_json]).to eq(true)
      end
    end
  end

  describe "AdminApi#_list_factors" do
    let(:admin) do
      Supabase::Auth::AdminApi.new(
        url: "http://localhost:9998",
        headers: { "Authorization" => "Bearer service-role-jwt" }
      )
    end

    it "validates user_id UUID and sends GET to admin/users/{user_id}/factors" do
      uid = SecureRandom.uuid
      allow(admin).to receive(:_request).and_return({ "factors" => [] })

      admin._list_factors(user_id: uid)

      expect(admin).to have_received(:_request) do |method, path, **_kwargs|
        expect(method).to eq(:get)
        expect(path).to eq("admin/users/#{uid}/factors")
      end
    end

    it "raises ArgumentError for invalid user_id" do
      expect { admin._list_factors(user_id: "bad") }.to raise_error(ArgumentError)
    end
  end

  describe "AdminApi#_delete_factor" do
    let(:admin) do
      Supabase::Auth::AdminApi.new(
        url: "http://localhost:9998",
        headers: { "Authorization" => "Bearer service-role-jwt" }
      )
    end

    it "validates both user_id and factor_id, sends DELETE to admin/users/{uid}/factors/{fid}" do
      uid = SecureRandom.uuid
      fid = SecureRandom.uuid
      allow(admin).to receive(:_request).and_return({})

      admin._delete_factor(user_id: uid, id: fid)

      expect(admin).to have_received(:_request) do |method, path, **_kwargs|
        expect(method).to eq(:delete)
        expect(path).to eq("admin/users/#{uid}/factors/#{fid}")
      end
    end

    it "raises ArgumentError for invalid user_id" do
      expect { admin._delete_factor(user_id: "bad", id: SecureRandom.uuid) }.to raise_error(ArgumentError)
    end

    it "raises ArgumentError for invalid factor_id" do
      expect { admin._delete_factor(user_id: SecureRandom.uuid, id: "bad") }.to raise_error(ArgumentError)
    end
  end

  # ── US-005: Audit MFA API Methods ──────────────────────────────────────────

  describe "MFA enroll" do
    it "always sends issuer for totp (even nil), matching Python body['issuer'] = params.get('issuer')" do
      setup_session(client, mock_session)
      allow(client).to receive(:_request).and_return({
        "id" => "factor-id",
        "type" => "totp",
        "friendly_name" => "my-totp",
        "totp" => { "qr_code" => "<svg>test</svg>", "secret" => "s", "uri" => "otpauth://..." }
      })

      client.mfa.enroll(factor_type: "totp", friendly_name: "my-totp")

      expect(client).to have_received(:_request) do |_method, _path, **kwargs|
        # Python always sends issuer (None if absent): body["issuer"] = params.get("issuer")
        expect(kwargs[:body]).to have_key(:issuer)
        expect(kwargs[:body][:issuer]).to be_nil
      end
    end

    it "sends friendly_name even when nil, matching Python body['friendly_name'] = params.get('friendly_name')" do
      setup_session(client, mock_session)
      allow(client).to receive(:_request).and_return({
        "id" => "factor-id",
        "type" => "totp",
        "friendly_name" => nil,
        "totp" => { "qr_code" => "<svg>test</svg>", "secret" => "s", "uri" => "otpauth://..." }
      })

      client.mfa.enroll(factor_type: "totp")

      expect(client).to have_received(:_request) do |_method, _path, **kwargs|
        expect(kwargs[:body]).to have_key(:friendly_name)
        expect(kwargs[:body][:friendly_name]).to be_nil
      end
    end

    it "does not include issuer or phone keys for phone factor type (only phone)" do
      setup_session(client, mock_session)
      allow(client).to receive(:_request).and_return({
        "id" => "factor-id",
        "type" => "phone",
        "friendly_name" => "my-phone"
      })

      client.mfa.enroll(factor_type: "phone", phone: "+15551234567")

      expect(client).to have_received(:_request) do |_method, _path, **kwargs|
        expect(kwargs[:body]).not_to have_key(:issuer)
        expect(kwargs[:body][:phone]).to eq("+15551234567")
      end
    end

    it "raises AuthSessionMissing without session, matching Python" do
      expect { client.mfa.enroll(factor_type: "totp") }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end

    it "prepends data URI to QR code for totp, matching Python f'data:image/svg+xml;utf-8,{...}'" do
      setup_session(client, mock_session)
      allow(client).to receive(:_request).and_return({
        "id" => "factor-id",
        "type" => "totp",
        "friendly_name" => "my-totp",
        "totp" => { "qr_code" => "<svg>test</svg>", "secret" => "JBSWY3DPEHPK3PXP", "uri" => "otpauth://totp/MyApp?secret=JBSWY3DPEHPK3PXP" }
      })

      response = client.mfa.enroll(factor_type: "totp", friendly_name: "my-totp")

      expect(response.totp.qr_code).to eq("data:image/svg+xml;utf-8,<svg>test</svg>")
    end

    it "does not prepend data URI for phone factor type" do
      setup_session(client, mock_session)
      allow(client).to receive(:_request).and_return({
        "id" => "factor-id",
        "type" => "phone",
        "friendly_name" => "my-phone",
        "phone" => "+15551234567"
      })

      response = client.mfa.enroll(factor_type: "phone", phone: "+15551234567")

      expect(response.totp).to be_nil
    end

    it "returns AuthMFAEnrollResponse with correct fields" do
      setup_session(client, mock_session)
      allow(client).to receive(:_request).and_return({
        "id" => "factor-abc",
        "type" => "totp",
        "friendly_name" => "work-totp",
        "totp" => { "qr_code" => "<svg/>", "secret" => "SECRET", "uri" => "otpauth://totp/test" }
      })

      response = client.mfa.enroll(factor_type: "totp", friendly_name: "work-totp", issuer: "TestApp")

      expect(response).to be_a(Supabase::Auth::Types::AuthMFAEnrollResponse)
      expect(response.id).to eq("factor-abc")
      expect(response.type).to eq("totp")
      expect(response.friendly_name).to eq("work-totp")
      expect(response.totp.secret).to eq("SECRET")
    end
  end

  describe "MFA challenge" do
    it "sends channel nil when not provided, matching Python body={'channel': params.get('channel')}" do
      setup_session(client, mock_session)
      allow(client).to receive(:_request).and_return({
        "id" => "challenge-id",
        "type" => "totp",
        "expires_at" => Time.now.to_i + 300
      })

      client.mfa.challenge(factor_id: "factor-123")

      expect(client).to have_received(:_request) do |_method, _path, **kwargs|
        expect(kwargs[:body][:channel]).to be_nil
      end
    end

    it "raises AuthSessionMissing without session" do
      expect { client.mfa.challenge(factor_id: "factor-123") }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end

    it "returns AuthMFAChallengeResponse with factor_type from 'type' field" do
      setup_session(client, mock_session)
      allow(client).to receive(:_request).and_return({
        "id" => "chal-id",
        "type" => "phone",
        "expires_at" => Time.now.to_i + 300
      })

      response = client.mfa.challenge(factor_id: "f-id")

      expect(response).to be_a(Supabase::Auth::Types::AuthMFAChallengeResponse)
      expect(response.factor_type).to eq("phone")
    end
  end

  describe "MFA verify" do
    it "sends full params as body matching Python body=params (factor_id, challenge_id, code)" do
      setup_session(client, mock_session)
      allow(client).to receive(:_request).and_return({
        "access_token" => "new-token",
        "refresh_token" => "new-refresh",
        "token_type" => "bearer",
        "expires_in" => 3600,
        "expires_at" => Time.now.to_i + 3600,
        "user" => { "id" => "uid", "app_metadata" => {}, "user_metadata" => {}, "aud" => "aud",
                     "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z" }
      })

      client.mfa.verify(factor_id: "f-1", challenge_id: "c-1", code: "123456")

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("factors/f-1/verify")
        expect(kwargs[:body][:factor_id]).to eq("f-1")
        expect(kwargs[:body][:challenge_id]).to eq("c-1")
        expect(kwargs[:body][:code]).to eq("123456")
      end
    end

    it "saves session and notifies MFA_CHALLENGE_VERIFIED, matching Python" do
      setup_session(client, mock_session)
      events = []
      client.on_auth_state_change { |event, session| events << event }

      allow(client).to receive(:_request).and_return({
        "access_token" => "mfa-token",
        "refresh_token" => "mfa-refresh",
        "token_type" => "bearer",
        "expires_in" => 3600,
        "expires_at" => Time.now.to_i + 3600,
        "user" => { "id" => "uid", "app_metadata" => {}, "user_metadata" => {}, "aud" => "aud",
                     "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z" }
      })

      client.mfa.verify(factor_id: "f-1", challenge_id: "c-1", code: "123456")

      expect(events).to include("MFA_CHALLENGE_VERIFIED")
    end

    it "raises AuthSessionMissing without session" do
      expect { client.mfa.verify(factor_id: "f", challenge_id: "c", code: "000000") }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end

    it "returns AuthMFAVerifyResponse" do
      setup_session(client, mock_session)
      allow(client).to receive(:_request).and_return({
        "access_token" => "new-token",
        "refresh_token" => "new-refresh",
        "token_type" => "bearer",
        "expires_in" => 3600,
        "expires_at" => Time.now.to_i + 3600,
        "user" => { "id" => "uid", "app_metadata" => {}, "user_metadata" => {}, "aud" => "aud",
                     "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z" }
      })

      response = client.mfa.verify(factor_id: "f-1", challenge_id: "c-1", code: "123456")

      expect(response).to be_a(Supabase::Auth::Types::AuthMFAVerifyResponse)
      expect(response.access_token).to eq("new-token")
    end
  end

  describe "MFA challenge_and_verify" do
    it "chains challenge + verify matching Python pattern" do
      setup_session(client, mock_session)
      call_count = 0
      allow(client).to receive(:_request) do |method, path, **kwargs|
        call_count += 1
        if path.end_with?("/challenge")
          { "id" => "chal-id", "type" => "totp", "expires_at" => Time.now.to_i + 300 }
        else
          { "access_token" => "t", "refresh_token" => "r", "token_type" => "bearer",
            "expires_in" => 3600, "expires_at" => Time.now.to_i + 3600,
            "user" => { "id" => "uid", "app_metadata" => {}, "user_metadata" => {}, "aud" => "aud",
                         "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z" } }
        end
      end

      response = client.mfa.challenge_and_verify(factor_id: "f-1", code: "123456")

      expect(call_count).to eq(2)
      expect(response).to be_a(Supabase::Auth::Types::AuthMFAVerifyResponse)
    end

    it "passes challenge_id from challenge response to verify, matching Python" do
      setup_session(client, mock_session)
      verify_body = nil
      allow(client).to receive(:_request) do |method, path, **kwargs|
        if path.end_with?("/challenge")
          { "id" => "generated-challenge-id", "type" => "totp", "expires_at" => Time.now.to_i + 300 }
        else
          verify_body = kwargs[:body]
          { "access_token" => "t", "refresh_token" => "r", "token_type" => "bearer",
            "expires_in" => 3600, "expires_at" => Time.now.to_i + 3600,
            "user" => { "id" => "uid", "app_metadata" => {}, "user_metadata" => {}, "aud" => "aud",
                         "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z" } }
        end
      end

      client.mfa.challenge_and_verify(factor_id: "f-1", code: "654321")

      expect(verify_body[:challenge_id]).to eq("generated-challenge-id")
      expect(verify_body[:code]).to eq("654321")
    end

    it "forwards channel parameter to challenge for phone factors" do
      setup_session(client, mock_session)
      challenge_body = nil
      allow(client).to receive(:_request) do |method, path, **kwargs|
        if path.end_with?("/challenge")
          challenge_body = kwargs[:body]
          { "id" => "chal-id", "type" => "phone", "expires_at" => Time.now.to_i + 300 }
        else
          { "access_token" => "t", "refresh_token" => "r", "token_type" => "bearer",
            "expires_in" => 3600, "expires_at" => Time.now.to_i + 3600,
            "user" => { "id" => "uid", "app_metadata" => {}, "user_metadata" => {}, "aud" => "aud",
                         "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z" } }
        end
      end

      client.mfa.challenge_and_verify(factor_id: "f-1", code: "123456", channel: "whatsapp")

      expect(challenge_body[:channel]).to eq("whatsapp")
    end

    it "passes nil channel when not provided, leaving behavior unchanged" do
      setup_session(client, mock_session)
      challenge_body = nil
      allow(client).to receive(:_request) do |method, path, **kwargs|
        if path.end_with?("/challenge")
          challenge_body = kwargs[:body]
          { "id" => "chal-id", "type" => "totp", "expires_at" => Time.now.to_i + 300 }
        else
          { "access_token" => "t", "refresh_token" => "r", "token_type" => "bearer",
            "expires_in" => 3600, "expires_at" => Time.now.to_i + 3600,
            "user" => { "id" => "uid", "app_metadata" => {}, "user_metadata" => {}, "aud" => "aud",
                         "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z" } }
        end
      end

      client.mfa.challenge_and_verify(factor_id: "f-1", code: "123456")

      expect(challenge_body[:channel]).to be_nil
    end
  end

  describe "MFA unenroll" do
    it "sends DELETE to factors/{factor_id} with session JWT, matching Python" do
      setup_session(client, mock_session)
      allow(client).to receive(:_request).and_return({ "id" => "factor-123" })

      client.mfa.unenroll(factor_id: "factor-123")

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("DELETE")
        expect(path).to eq("factors/factor-123")
        expect(kwargs[:jwt]).to eq("mock-access-token")
      end
    end

    it "raises AuthSessionMissing without session" do
      expect { client.mfa.unenroll(factor_id: "f") }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end

    it "returns AuthMFAUnenrollResponse" do
      setup_session(client, mock_session)
      allow(client).to receive(:_request).and_return({ "id" => "factor-xyz" })

      response = client.mfa.unenroll(factor_id: "factor-xyz")

      expect(response).to be_a(Supabase::Auth::Types::AuthMFAUnenrollResponse)
      expect(response.id).to eq("factor-xyz")
    end
  end

  describe "MFA list_factors" do
    it "calls get_user without JWT (no explicit access_token), matching Python self.get_user()" do
      setup_session(client, mock_session)
      allow(client).to receive(:get_user).and_return(
        Supabase::Auth::Types::UserResponse.new(
          user: Supabase::Auth::Types::User.new(
            id: "uid", aud: "aud", app_metadata: {}, user_metadata: {},
            created_at: Time.now, updated_at: Time.now,
            factors: [
              Supabase::Auth::Types::Factor.new(id: "f1", factor_type: "totp", status: "verified"),
              Supabase::Auth::Types::Factor.new(id: "f2", factor_type: "phone", status: "verified"),
              Supabase::Auth::Types::Factor.new(id: "f3", factor_type: "totp", status: "unverified")
            ]
          )
        )
      )

      response = client.mfa.list_factors

      # Must call get_user() with no arguments (matching Python)
      expect(client).to have_received(:get_user).with(no_args)

      expect(response).to be_a(Supabase::Auth::Types::AuthMFAListFactorsResponse)
      expect(response.all.length).to eq(3)
      expect(response.totp.length).to eq(1)
      expect(response.totp.first.id).to eq("f1")
      expect(response.phone.length).to eq(1)
      expect(response.phone.first.id).to eq("f2")
    end

    it "filters only verified factors for totp and phone, matching Python list comprehension" do
      setup_session(client, mock_session)
      allow(client).to receive(:get_user).and_return(
        Supabase::Auth::Types::UserResponse.new(
          user: Supabase::Auth::Types::User.new(
            id: "uid", aud: "aud", app_metadata: {}, user_metadata: {},
            created_at: Time.now, updated_at: Time.now,
            factors: [
              Supabase::Auth::Types::Factor.new(id: "f1", factor_type: "totp", status: "unverified"),
              Supabase::Auth::Types::Factor.new(id: "f2", factor_type: "phone", status: "unverified")
            ]
          )
        )
      )

      response = client.mfa.list_factors

      expect(response.all.length).to eq(2)
      expect(response.totp).to be_empty
      expect(response.phone).to be_empty
    end

    it "handles nil factors, matching Python 'response.user.factors or []'" do
      setup_session(client, mock_session)
      allow(client).to receive(:get_user).and_return(
        Supabase::Auth::Types::UserResponse.new(
          user: Supabase::Auth::Types::User.new(
            id: "uid", aud: "aud", app_metadata: {}, user_metadata: {},
            created_at: Time.now, updated_at: Time.now,
            factors: nil
          )
        )
      )

      response = client.mfa.list_factors

      expect(response.all).to eq([])
      expect(response.totp).to eq([])
      expect(response.phone).to eq([])
    end
  end

  describe "MFA get_authenticator_assurance_level" do
    it "returns nil levels with empty methods when no session, matching Python" do
      response = client.mfa.get_authenticator_assurance_level

      expect(response.current_level).to be_nil
      expect(response.next_level).to be_nil
      expect(response.current_authentication_methods).to eq([])
    end

    it "parses AAL and AMR from JWT payload, matching Python decode_jwt" do
      # Create a JWT with aal and amr claims
      payload = { "aal" => "aal1", "amr" => [{ "method" => "password", "timestamp" => Time.now.to_i }],
                  "sub" => "user-id", "exp" => Time.now.to_i + 3600 }
      jwt = JWT.encode(payload, "test-secret", "HS256")

      session_with_jwt = Supabase::Auth::Types::Session.new(
        access_token: jwt,
        refresh_token: "refresh",
        expires_in: 3600,
        expires_at: Time.now.to_i + 3600,
        token_type: "bearer",
        user: mock_user
      )
      setup_session(client, session_with_jwt)

      response = client.mfa.get_authenticator_assurance_level

      expect(response.current_level).to eq("aal1")
      expect(response.current_authentication_methods.length).to eq(1)
      expect(response.current_authentication_methods.first["method"]).to eq("password")
    end

    it "sets next_level to aal2 when verified factors exist, matching Python" do
      payload = { "aal" => "aal1", "amr" => [], "sub" => "user-id", "exp" => Time.now.to_i + 3600 }
      jwt = JWT.encode(payload, "test-secret", "HS256")

      user_with_factors = Supabase::Auth::Types::User.new(
        id: "uid", aud: "aud", app_metadata: {}, user_metadata: {},
        created_at: Time.now, updated_at: Time.now,
        factors: [
          Supabase::Auth::Types::Factor.new(id: "f1", factor_type: "totp", status: "verified")
        ]
      )
      session_with_factors = Supabase::Auth::Types::Session.new(
        access_token: jwt, refresh_token: "r", expires_in: 3600,
        expires_at: Time.now.to_i + 3600, token_type: "bearer", user: user_with_factors
      )
      setup_session(client, session_with_factors)

      response = client.mfa.get_authenticator_assurance_level

      expect(response.next_level).to eq("aal2")
    end

    it "sets next_level to current AAL when no verified factors, matching Python" do
      payload = { "aal" => "aal1", "amr" => [], "sub" => "user-id", "exp" => Time.now.to_i + 3600 }
      jwt = JWT.encode(payload, "test-secret", "HS256")

      session = Supabase::Auth::Types::Session.new(
        access_token: jwt, refresh_token: "r", expires_in: 3600,
        expires_at: Time.now.to_i + 3600, token_type: "bearer",
        user: Supabase::Auth::Types::User.new(
          id: "uid", aud: "aud", app_metadata: {}, user_metadata: {},
          created_at: Time.now, updated_at: Time.now, factors: []
        )
      )
      setup_session(client, session)

      response = client.mfa.get_authenticator_assurance_level

      expect(response.next_level).to eq("aal1")
    end

    it "handles nil amr in JWT, matching Python payload.get('amr') or []" do
      payload = { "aal" => "aal1", "sub" => "user-id", "exp" => Time.now.to_i + 3600 }
      jwt = JWT.encode(payload, "test-secret", "HS256")

      session = Supabase::Auth::Types::Session.new(
        access_token: jwt, refresh_token: "r", expires_in: 3600,
        expires_at: Time.now.to_i + 3600, token_type: "bearer", user: mock_user
      )
      setup_session(client, session)

      response = client.mfa.get_authenticator_assurance_level

      expect(response.current_authentication_methods).to eq([])
    end
  end
end
