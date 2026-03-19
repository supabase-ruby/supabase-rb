# frozen_string_literal: true

require "spec_helper"

# US-001: Audit Client Authentication Methods
# Verifies that all client authentication methods (sign_up, sign_in_with_password,
# sign_in_with_otp, sign_in_with_oauth, sign_in_with_sso, sign_in_with_id_token,
# sign_in_anonymously) match Python's parameter handling, request body construction,
# and response parsing.
RSpec.describe "US-001: Client Authentication Methods Audit" do
  let(:client) do
    Supabase::Auth::Client.new(
      url: "http://localhost:9998",
      auto_refresh_token: false,
      persist_session: false
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

  # ── AC-1: Each auth method exists in Ruby with identical parameters ──

  describe "AC-1: All authentication methods exist" do
    it "has sign_up method" do
      expect(client).to respond_to(:sign_up)
    end

    it "has sign_in_with_password method" do
      expect(client).to respond_to(:sign_in_with_password)
    end

    it "has sign_in_with_otp method" do
      expect(client).to respond_to(:sign_in_with_otp)
    end

    it "has sign_in_with_oauth method" do
      expect(client).to respond_to(:sign_in_with_oauth)
    end

    it "has sign_in_with_sso method" do
      expect(client).to respond_to(:sign_in_with_sso)
    end

    it "has sign_in_with_id_token method" do
      expect(client).to respond_to(:sign_in_with_id_token)
    end

    it "has sign_in_anonymously method" do
      expect(client).to respond_to(:sign_in_anonymously)
    end
  end

  # ── AC-2: Request bodies match Python's construction ──

  describe "AC-2: Request body construction matches Python" do
    before { allow(client).to receive(:_request).and_return(mock_auth_data) }

    describe "sign_up" do
      it "email signup body: email, password, data, gotrue_meta_security (no phone/channel)" do
        client.sign_up(email: "a@b.com", password: "pass", options: { data: { "k" => "v" }, captcha_token: "ct" })

        expect(client).to have_received(:_request) do |method, path, **kwargs|
          expect(method).to eq("POST")
          expect(path).to eq("signup")
          expect(kwargs[:body]).to eq({
            email: "a@b.com",
            password: "pass",
            data: { "k" => "v" },
            gotrue_meta_security: { captcha_token: "ct" }
          })
        end
      end

      it "phone signup body: phone, password, data, channel, gotrue_meta_security (no email)" do
        client.sign_up(phone: "+123", password: "pass", options: { channel: "whatsapp", captcha_token: "ct" })

        expect(client).to have_received(:_request) do |_m, _p, **kwargs|
          expect(kwargs[:body]).to eq({
            phone: "+123",
            password: "pass",
            data: {},
            channel: "whatsapp",
            gotrue_meta_security: { captcha_token: "ct" }
          })
        end
      end
    end

    describe "sign_in_with_password" do
      it "email body: email, password, data, gotrue_meta_security + grant_type=password param" do
        client.sign_in_with_password(email: "a@b.com", password: "pass", options: { captcha_token: "ct" })

        expect(client).to have_received(:_request) do |method, path, **kwargs|
          expect(method).to eq("POST")
          expect(path).to eq("token")
          expect(kwargs[:body][:email]).to eq("a@b.com")
          expect(kwargs[:body][:password]).to eq("pass")
          expect(kwargs[:body][:gotrue_meta_security]).to eq({ captcha_token: "ct" })
          expect(kwargs[:params]).to eq({ "grant_type" => "password" })
        end
      end

      it "phone body: phone, password, data, gotrue_meta_security + grant_type=password param" do
        client.sign_in_with_password(phone: "+123", password: "pass")

        expect(client).to have_received(:_request) do |_m, _p, **kwargs|
          expect(kwargs[:body][:phone]).to eq("+123")
          expect(kwargs[:body][:password]).to eq("pass")
          expect(kwargs[:params]).to eq({ "grant_type" => "password" })
        end
      end
    end

    describe "sign_in_with_otp" do
      before { allow(client).to receive(:_request).and_return({ "message_id" => "msg" }) }

      it "email OTP body: email, data, create_user, gotrue_meta_security (no channel)" do
        client.sign_in_with_otp(email: "a@b.com", options: { data: { "k" => "v" }, captcha_token: "ct" })

        expect(client).to have_received(:_request) do |_m, _p, **kwargs|
          expect(kwargs[:body][:email]).to eq("a@b.com")
          expect(kwargs[:body][:data]).to eq({ "k" => "v" })
          expect(kwargs[:body][:create_user]).to eq(true)
          expect(kwargs[:body][:gotrue_meta_security]).to eq({ captcha_token: "ct" })
          expect(kwargs[:body]).not_to have_key(:channel)
        end
      end

      it "phone OTP body: phone, data, create_user, channel, gotrue_meta_security" do
        client.sign_in_with_otp(phone: "+123", options: { channel: "whatsapp" })

        expect(client).to have_received(:_request) do |_m, _p, **kwargs|
          expect(kwargs[:body][:phone]).to eq("+123")
          expect(kwargs[:body][:channel]).to eq("whatsapp")
          expect(kwargs[:body][:create_user]).to eq(true)
          expect(kwargs[:body]).not_to have_key(:email)
        end
      end
    end

    describe "sign_in_with_id_token" do
      it "body: provider, id_token, access_token, nonce, gotrue_meta_security + grant_type=id_token" do
        client.sign_in_with_id_token(
          provider: "google", token: "id-tok", access_token: "at", nonce: "n",
          options: { captcha_token: "ct" }
        )

        expect(client).to have_received(:_request) do |_m, _p, **kwargs|
          expect(kwargs[:body]).to eq({
            provider: "google", id_token: "id-tok", access_token: "at", nonce: "n",
            gotrue_meta_security: { captcha_token: "ct" }
          })
          expect(kwargs[:params]).to eq({ "grant_type" => "id_token" })
        end
      end
    end

    describe "sign_in_with_sso" do
      before { allow(client).to receive(:_request).and_return({ "url" => "https://sso.test" }) }

      it "domain body: domain, skip_http_redirect, gotrue_meta_security, redirect_to" do
        client.sign_in_with_sso(domain: "ex.com", options: { redirect_to: "https://app.com", captcha_token: "ct" })

        expect(client).to have_received(:_request) do |_m, _p, **kwargs|
          expect(kwargs[:body]).to eq({
            domain: "ex.com",
            skip_http_redirect: true,
            gotrue_meta_security: { captcha_token: "ct" },
            redirect_to: "https://app.com"
          })
        end
      end

      it "provider_id body: provider_id, skip_http_redirect, gotrue_meta_security, redirect_to" do
        client.sign_in_with_sso(provider_id: "pid", options: { captcha_token: "ct" })

        expect(client).to have_received(:_request) do |_m, _p, **kwargs|
          expect(kwargs[:body][:provider_id]).to eq("pid")
          expect(kwargs[:body][:skip_http_redirect]).to eq(true)
          expect(kwargs[:body][:gotrue_meta_security]).to eq({ captcha_token: "ct" })
        end
      end
    end

    describe "sign_in_anonymously" do
      it "body: data, gotrue_meta_security (no email/phone/password)" do
        client.sign_in_anonymously(options: { data: { "anon" => true }, captcha_token: "ct" })

        expect(client).to have_received(:_request) do |_m, path, **kwargs|
          expect(path).to eq("signup")
          expect(kwargs[:body]).to eq({
            data: { "anon" => true },
            gotrue_meta_security: { captcha_token: "ct" }
          })
        end
      end
    end

    describe "sign_in_with_oauth" do
      it "constructs URL with provider, redirect_to, scopes, query_params" do
        response = client.sign_in_with_oauth(
          provider: "github",
          options: { redirect_to: "https://app.com", scopes: "repo", query_params: { "extra" => "val" } }
        )

        expect(response).to be_a(Supabase::Auth::Types::OAuthResponse)
        expect(response.provider).to eq("github")
        expect(response.url).to include("provider=github")
        expect(response.url).to include("redirect_to=")
        expect(response.url).to include("scopes=repo")
        expect(response.url).to include("extra=val")
      end
    end
  end

  # ── AC-3: Response parsing produces equivalent typed objects ──

  describe "AC-3: Response parsing" do
    before { allow(client).to receive(:_request).and_return(mock_auth_data) }

    it "sign_up returns AuthResponse with session and user" do
      response = client.sign_up(email: "a@b.com", password: "pass")
      expect(response).to be_a(Supabase::Auth::Types::AuthResponse)
      expect(response.session).to be_a(Supabase::Auth::Types::Session)
      expect(response.user).to be_a(Supabase::Auth::Types::User)
    end

    it "sign_in_with_password returns AuthResponse" do
      response = client.sign_in_with_password(email: "a@b.com", password: "pass")
      expect(response).to be_a(Supabase::Auth::Types::AuthResponse)
      expect(response.session).not_to be_nil
    end

    it "sign_in_with_otp returns AuthOtpResponse" do
      allow(client).to receive(:_request).and_return({ "message_id" => "msg-123" })
      response = client.sign_in_with_otp(email: "a@b.com")
      expect(response).to be_a(Supabase::Auth::Types::AuthOtpResponse)
    end

    it "sign_in_with_id_token returns AuthResponse" do
      response = client.sign_in_with_id_token(provider: "google", token: "tok")
      expect(response).to be_a(Supabase::Auth::Types::AuthResponse)
    end

    it "sign_in_anonymously returns AuthResponse" do
      response = client.sign_in_anonymously
      expect(response).to be_a(Supabase::Auth::Types::AuthResponse)
    end

    it "sign_in_with_sso returns SSOResponse" do
      allow(client).to receive(:_request).and_return({ "url" => "https://sso.test" })
      response = client.sign_in_with_sso(domain: "ex.com")
      expect(response).to be_a(Supabase::Auth::Types::SSOResponse)
    end

    it "sign_in_with_oauth returns OAuthResponse" do
      response = client.sign_in_with_oauth(provider: "github")
      expect(response).to be_a(Supabase::Auth::Types::OAuthResponse)
    end
  end

  # ── AC-4: Default values match Python defaults ──

  describe "AC-4: Default values" do
    before { allow(client).to receive(:_request).and_return(mock_auth_data) }

    it "sign_up defaults data to {} (matching Python options.get('data') or {})" do
      client.sign_up(email: "a@b.com", password: "pass")
      expect(client).to have_received(:_request) do |_m, _p, **kwargs|
        expect(kwargs[:body][:data]).to eq({})
      end
    end

    it "sign_up defaults channel to 'sms' for phone (matching Python options.get('channel', 'sms'))" do
      client.sign_up(phone: "+123", password: "pass")
      expect(client).to have_received(:_request) do |_m, _p, **kwargs|
        expect(kwargs[:body][:channel]).to eq("sms")
      end
    end

    it "sign_in_with_password defaults data to {} (matching Python options.get('data') or {})" do
      client.sign_in_with_password(email: "a@b.com", password: "pass")
      expect(client).to have_received(:_request) do |_m, _p, **kwargs|
        expect(kwargs[:body][:data]).to eq({})
      end
    end

    it "sign_in_with_otp defaults should_create_user to true (matching Python options.get('should_create_user', True))" do
      allow(client).to receive(:_request).and_return({ "message_id" => "msg" })
      client.sign_in_with_otp(email: "a@b.com")
      expect(client).to have_received(:_request) do |_m, _p, **kwargs|
        expect(kwargs[:body][:create_user]).to eq(true)
      end
    end

    it "sign_in_with_otp defaults channel to 'sms' for phone (matching Python options.get('channel', 'sms'))" do
      allow(client).to receive(:_request).and_return({ "message_id" => "msg" })
      client.sign_in_with_otp(phone: "+123")
      expect(client).to have_received(:_request) do |_m, _p, **kwargs|
        expect(kwargs[:body][:channel]).to eq("sms")
      end
    end

    it "sign_in_with_sso defaults skip_http_redirect to true (matching Python options.get('skip_http_redirect', True))" do
      allow(client).to receive(:_request).and_return({ "url" => "https://sso.test" })
      client.sign_in_with_sso(domain: "ex.com")
      expect(client).to have_received(:_request) do |_m, _p, **kwargs|
        expect(kwargs[:body][:skip_http_redirect]).to eq(true)
      end
    end

    it "sign_in_anonymously defaults data to {} when no credentials" do
      client.sign_in_anonymously
      expect(client).to have_received(:_request) do |_m, _p, **kwargs|
        expect(kwargs[:body][:data]).to eq({})
      end
    end
  end

  # ── AC-5: redirect_to / email_redirect_to fallback logic ──

  describe "AC-5: redirect_to / email_redirect_to fallback logic" do
    before { allow(client).to receive(:_request).and_return(mock_auth_data) }

    it "sign_up uses redirect_to from options (matching Python options.get('redirect_to'))" do
      client.sign_up(email: "a@b.com", password: "pass", options: { redirect_to: "https://app.com" })
      expect(client).to have_received(:_request) do |_m, _p, **kwargs|
        expect(kwargs[:redirect_to]).to eq("https://app.com")
      end
    end

    it "sign_up falls back to email_redirect_to (matching Python 'or options.get(\"email_redirect_to\")')" do
      client.sign_up(email: "a@b.com", password: "pass", options: { email_redirect_to: "https://fallback.com" })
      expect(client).to have_received(:_request) do |_m, _p, **kwargs|
        expect(kwargs[:redirect_to]).to eq("https://fallback.com")
      end
    end

    it "sign_up prefers redirect_to over email_redirect_to" do
      client.sign_up(
        email: "a@b.com", password: "pass",
        options: { redirect_to: "https://primary.com", email_redirect_to: "https://fallback.com" }
      )
      expect(client).to have_received(:_request) do |_m, _p, **kwargs|
        expect(kwargs[:redirect_to]).to eq("https://primary.com")
      end
    end

    it "sign_in_with_otp passes email_redirect_to as redirect_to for email OTP" do
      allow(client).to receive(:_request).and_return({ "message_id" => "msg" })
      client.sign_in_with_otp(email: "a@b.com", options: { email_redirect_to: "https://otp.com" })
      expect(client).to have_received(:_request) do |_m, _p, **kwargs|
        expect(kwargs[:redirect_to]).to eq("https://otp.com")
      end
    end

    it "sign_in_with_otp does NOT pass redirect_to for phone OTP (matching Python)" do
      allow(client).to receive(:_request).and_return({ "message_id" => "msg" })
      client.sign_in_with_otp(phone: "+123")
      expect(client).to have_received(:_request) do |_m, _p, **kwargs|
        expect(kwargs[:redirect_to]).to be_nil
      end
    end
  end

  # ── Each method calls _remove_session before auth ──

  describe "All auth methods call _remove_session before starting" do
    before do
      allow(client).to receive(:_request).and_return(mock_auth_data)
      allow(client).to receive(:_remove_session).and_call_original
    end

    %i[sign_up sign_in_with_password sign_in_with_id_token sign_in_anonymously].each do |method|
      it "#{method} calls _remove_session" do
        case method
        when :sign_up
          client.sign_up(email: "a@b.com", password: "pass")
        when :sign_in_with_password
          client.sign_in_with_password(email: "a@b.com", password: "pass")
        when :sign_in_with_id_token
          client.sign_in_with_id_token(provider: "google", token: "tok")
        when :sign_in_anonymously
          client.sign_in_anonymously
        end

        expect(client).to have_received(:_remove_session).at_least(:once)
      end
    end

    it "sign_in_with_otp calls _remove_session" do
      allow(client).to receive(:_request).and_return({ "message_id" => "msg" })
      client.sign_in_with_otp(email: "a@b.com")
      expect(client).to have_received(:_remove_session).at_least(:once)
    end

    it "sign_in_with_sso calls _remove_session" do
      allow(client).to receive(:_request).and_return({ "url" => "https://sso.test" })
      client.sign_in_with_sso(domain: "ex.com")
      expect(client).to have_received(:_remove_session).at_least(:once)
    end

    it "sign_in_with_oauth calls _remove_session" do
      client.sign_in_with_oauth(provider: "github")
      expect(client).to have_received(:_remove_session).at_least(:once)
    end
  end

  # ── Error handling: invalid credentials ──

  describe "Error handling matches Python" do
    it "sign_up raises AuthInvalidCredentialsError without email or phone" do
      expect { client.sign_up(password: "pass") }
        .to raise_error(Supabase::Auth::Errors::AuthInvalidCredentialsError)
    end

    it "sign_in_with_password raises AuthInvalidCredentialsError without email/phone and password" do
      expect { client.sign_in_with_password({}) }
        .to raise_error(Supabase::Auth::Errors::AuthInvalidCredentialsError)
    end

    it "sign_in_with_otp raises AuthInvalidCredentialsError without email or phone" do
      expect { client.sign_in_with_otp({}) }
        .to raise_error(Supabase::Auth::Errors::AuthInvalidCredentialsError)
    end

    it "sign_in_with_sso raises AuthInvalidCredentialsError without domain or provider_id" do
      expect { client.sign_in_with_sso({}) }
        .to raise_error(Supabase::Auth::Errors::AuthInvalidCredentialsError)
    end
  end

  # ── Session save + event notification on successful auth ──

  describe "Session save and SIGNED_IN notification" do
    it "saves session and emits SIGNED_IN on successful sign_up" do
      allow(client).to receive(:_request).and_return(mock_auth_data)
      events = []
      client.on_auth_state_change { |event, _session| events << event }

      response = client.sign_up(email: "a@b.com", password: "pass")

      expect(response.session).not_to be_nil
      expect(events).to include("SIGNED_IN")
    end

    it "saves session and emits SIGNED_IN on successful sign_in_with_password" do
      allow(client).to receive(:_request).and_return(mock_auth_data)
      events = []
      client.on_auth_state_change { |event, _session| events << event }

      response = client.sign_in_with_password(email: "a@b.com", password: "pass")

      expect(response.session).not_to be_nil
      expect(events).to include("SIGNED_IN")
    end

    it "saves session and emits SIGNED_IN on successful sign_in_anonymously" do
      allow(client).to receive(:_request).and_return(mock_auth_data)
      events = []
      client.on_auth_state_change { |event, _session| events << event }

      response = client.sign_in_anonymously

      expect(response.session).not_to be_nil
      expect(events).to include("SIGNED_IN")
    end

    it "does NOT save session when sign_up returns no session (email confirmation)" do
      allow(client).to receive(:_request).and_return({ "user" => mock_auth_data["user"] })
      allow(client).to receive(:_save_session)

      response = client.sign_up(email: "a@b.com", password: "pass")

      expect(response.session).to be_nil
      expect(client).not_to have_received(:_save_session)
    end
  end
end
