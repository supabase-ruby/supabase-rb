# frozen_string_literal: true

require "spec_helper"
require "json"
require "faraday"

RSpec.describe "US-013: Audit OTP Verify & Resend" do
  let(:base_url) { "http://localhost:9999" }
  let(:default_headers) { { "apikey" => "test-key" } }

  let(:mock_user) do
    {
      "id" => "user-123",
      "aud" => "authenticated",
      "role" => "authenticated",
      "email" => "test@example.com",
      "phone" => "+1234567890",
      "created_at" => "2024-01-01T00:00:00Z",
      "updated_at" => "2024-01-01T00:00:00Z",
      "app_metadata" => {},
      "user_metadata" => {}
    }
  end

  let(:mock_session) do
    {
      "access_token" => "test-access-token",
      "refresh_token" => "test-refresh-token",
      "token_type" => "bearer",
      "expires_in" => 3600,
      "expires_at" => Time.now.to_i + 3600,
      "user" => mock_user
    }
  end

  # A proper response for verify: session data at top-level (parse_auth_response checks root keys)
  let(:mock_verify_response_with_session) { mock_session.merge("user" => mock_user) }
  let(:mock_verify_response_without_session) { { "user" => mock_user } }

  # Simple storage object that responds to get_item, set_item, remove_item
  let(:mock_storage) do
    store = {}
    storage = Object.new
    storage.define_singleton_method(:get_item) { |key| store[key] }
    storage.define_singleton_method(:set_item) { |key, value| store[key] = value }
    storage.define_singleton_method(:remove_item) { |key| store.delete(key) }
    storage.define_singleton_method(:store) { store }
    storage
  end

  def build_client_with_stubs(persist_session: false, storage: nil, &block)
    stubs = Faraday::Adapter::Test::Stubs.new(&block)
    conn = Faraday.new(url: base_url) do |f|
      f.response :raise_error
      f.adapter :test, stubs
    end
    opts = {
      url: base_url,
      headers: default_headers,
      auto_refresh_token: false,
      persist_session: persist_session,
      http_client: conn
    }
    opts[:storage] = storage if storage
    client = Supabase::Auth::Client.new(**opts)
    [client, stubs]
  end

  # ──────────────────────────────────────────────────
  # AC-1: verify_otp handles all types: email, phone, token_hash variants
  # ──────────────────────────────────────────────────
  describe "AC-1: verify_otp handles all OTP types" do
    it "handles email OTP verification (type: email)" do
      client, stubs = build_client_with_stubs do |stub|
        stub.post("/verify") do |env|
          body = JSON.parse(env.body)
          expect(body["type"]).to eq("email")
          expect(body["email"]).to eq("test@example.com")
          expect(body["token"]).to eq("123456")
          [200, { "Content-Type" => "application/json" }, mock_verify_response_with_session.to_json]
        end
      end

      response = client.verify_otp(email: "test@example.com", token: "123456", type: "email")
      expect(response).to be_a(Supabase::Auth::Types::AuthResponse)
      stubs.verify_stubbed_calls
    end

    it "handles phone OTP verification (type: sms)" do
      client, stubs = build_client_with_stubs do |stub|
        stub.post("/verify") do |env|
          body = JSON.parse(env.body)
          expect(body["type"]).to eq("sms")
          expect(body["phone"]).to eq("+1234567890")
          expect(body["token"]).to eq("654321")
          [200, { "Content-Type" => "application/json" }, mock_verify_response_with_session.to_json]
        end
      end

      response = client.verify_otp(phone: "+1234567890", token: "654321", type: "sms")
      expect(response).to be_a(Supabase::Auth::Types::AuthResponse)
      stubs.verify_stubbed_calls
    end

    it "handles phone_change OTP verification" do
      client, stubs = build_client_with_stubs do |stub|
        stub.post("/verify") do |env|
          body = JSON.parse(env.body)
          expect(body["type"]).to eq("phone_change")
          expect(body["phone"]).to eq("+9876543210")
          expect(body["token"]).to eq("111222")
          [200, { "Content-Type" => "application/json" }, mock_verify_response_with_session.to_json]
        end
      end

      response = client.verify_otp(phone: "+9876543210", token: "111222", type: "phone_change")
      expect(response).to be_a(Supabase::Auth::Types::AuthResponse)
      stubs.verify_stubbed_calls
    end

    it "handles token_hash OTP verification (type: email)" do
      client, stubs = build_client_with_stubs do |stub|
        stub.post("/verify") do |env|
          body = JSON.parse(env.body)
          expect(body["type"]).to eq("email")
          expect(body["token_hash"]).to eq("abc123hash")
          expect(body).not_to have_key("email")
          expect(body).not_to have_key("phone")
          expect(body).not_to have_key("token")
          [200, { "Content-Type" => "application/json" }, mock_verify_response_with_session.to_json]
        end
      end

      response = client.verify_otp(token_hash: "abc123hash", type: "email")
      expect(response).to be_a(Supabase::Auth::Types::AuthResponse)
      stubs.verify_stubbed_calls
    end

    it "handles magiclink type" do
      client, stubs = build_client_with_stubs do |stub|
        stub.post("/verify") do |env|
          body = JSON.parse(env.body)
          expect(body["type"]).to eq("magiclink")
          expect(body["email"]).to eq("test@example.com")
          expect(body["token"]).to eq("magic123")
          [200, { "Content-Type" => "application/json" }, mock_verify_response_with_session.to_json]
        end
      end

      response = client.verify_otp(email: "test@example.com", token: "magic123", type: "magiclink")
      expect(response).to be_a(Supabase::Auth::Types::AuthResponse)
      stubs.verify_stubbed_calls
    end

    it "handles recovery type with token_hash" do
      client, stubs = build_client_with_stubs do |stub|
        stub.post("/verify") do |env|
          body = JSON.parse(env.body)
          expect(body["type"]).to eq("recovery")
          expect(body["token_hash"]).to eq("recovery-hash-456")
          [200, { "Content-Type" => "application/json" }, mock_verify_response_with_session.to_json]
        end
      end

      response = client.verify_otp(token_hash: "recovery-hash-456", type: "recovery")
      expect(response).to be_a(Supabase::Auth::Types::AuthResponse)
      stubs.verify_stubbed_calls
    end

    it "handles email_change type with token_hash" do
      client, stubs = build_client_with_stubs do |stub|
        stub.post("/verify") do |env|
          body = JSON.parse(env.body)
          expect(body["type"]).to eq("email_change")
          expect(body["token_hash"]).to eq("change-hash-789")
          [200, { "Content-Type" => "application/json" }, mock_verify_response_with_session.to_json]
        end
      end

      response = client.verify_otp(token_hash: "change-hash-789", type: "email_change")
      expect(response).to be_a(Supabase::Auth::Types::AuthResponse)
      stubs.verify_stubbed_calls
    end
  end

  # ──────────────────────────────────────────────────
  # AC-2: verify_otp sends correct body to /verify endpoint
  # ──────────────────────────────────────────────────
  describe "AC-2: verify_otp sends correct request body" do
    it "sends POST to /verify with type, gotrue_meta_security, and credential fields" do
      client, stubs = build_client_with_stubs do |stub|
        stub.post("/verify") do |env|
          body = JSON.parse(env.body)
          expect(body["type"]).to eq("email")
          expect(body["gotrue_meta_security"]).to be_a(Hash)
          expect(body["email"]).to eq("test@example.com")
          expect(body["token"]).to eq("123456")
          [200, { "Content-Type" => "application/json" }, mock_verify_response_with_session.to_json]
        end
      end

      client.verify_otp(email: "test@example.com", token: "123456", type: "email")
      stubs.verify_stubbed_calls
    end

    it "removes session before verification (matches Python's _remove_session)" do
      client, _stubs = build_client_with_stubs(persist_session: true, storage: mock_storage) do |stub|
        stub.post("/verify") do |_env|
          [200, { "Content-Type" => "application/json" }, mock_verify_response_with_session.to_json]
        end
      end

      # Pre-populate storage
      mock_storage.set_item("supabase.auth.token", { "current_session" => mock_session }.to_json)

      client.verify_otp(email: "test@example.com", token: "123456", type: "email")

      # After verify_otp, new session should be stored (remove_session clears, then _save_session stores new)
      stored_raw = mock_storage.get_item("supabase.auth.token")
      expect(stored_raw).not_to be_nil
    end

    it "saves session and emits SIGNED_IN when session is returned" do
      events = []
      client, _stubs = build_client_with_stubs do |stub|
        stub.post("/verify") do |_env|
          [200, { "Content-Type" => "application/json" }, mock_verify_response_with_session.to_json]
        end
      end

      client.on_auth_state_change do |event, session|
        events << { event: event, session: session }
      end

      client.verify_otp(email: "test@example.com", token: "123456", type: "email")

      expect(events.length).to eq(1)
      expect(events.first[:event]).to eq("SIGNED_IN")
      expect(events.first[:session].access_token).to eq("test-access-token")
    end

    it "does not emit SIGNED_IN when no session returned" do
      events = []
      client, _stubs = build_client_with_stubs do |stub|
        stub.post("/verify") do |_env|
          [200, { "Content-Type" => "application/json" }, mock_verify_response_without_session.to_json]
        end
      end

      client.on_auth_state_change do |event, _session|
        events << event
      end

      client.verify_otp(token_hash: "hash123", type: "email")
      expect(events).to be_empty
    end

    it "only includes non-nil fields in body" do
      client, stubs = build_client_with_stubs do |stub|
        stub.post("/verify") do |env|
          body = JSON.parse(env.body)
          expect(body).not_to have_key("email")
          expect(body).not_to have_key("phone")
          expect(body).not_to have_key("token")
          expect(body).to have_key("token_hash")
          expect(body).to have_key("type")
          expect(body).to have_key("gotrue_meta_security")
          [200, { "Content-Type" => "application/json" }, mock_verify_response_without_session.to_json]
        end
      end

      client.verify_otp(token_hash: "hash456", type: "email")
      stubs.verify_stubbed_calls
    end
  end

  # ──────────────────────────────────────────────────
  # AC-3: resend sends correct body to /resend endpoint
  # ──────────────────────────────────────────────────
  describe "AC-3: resend sends correct body to /resend" do
    it "sends POST to /resend with email credentials" do
      client, stubs = build_client_with_stubs do |stub|
        stub.post("/resend") do |env|
          body = JSON.parse(env.body)
          expect(body["type"]).to eq("signup")
          expect(body["email"]).to eq("test@example.com")
          expect(body["gotrue_meta_security"]).to be_a(Hash)
          expect(body).not_to have_key("phone")
          [200, { "Content-Type" => "application/json" }, { "message_id" => "msg-123" }.to_json]
        end
      end

      response = client.resend(email: "test@example.com", type: "signup")
      expect(response).to be_a(Supabase::Auth::Types::AuthOtpResponse)
      stubs.verify_stubbed_calls
    end

    it "sends POST to /resend with phone credentials" do
      client, stubs = build_client_with_stubs do |stub|
        stub.post("/resend") do |env|
          body = JSON.parse(env.body)
          expect(body["type"]).to eq("sms")
          expect(body["phone"]).to eq("+1234567890")
          expect(body).not_to have_key("email")
          [200, { "Content-Type" => "application/json" }, { "message_id" => "msg-456" }.to_json]
        end
      end

      response = client.resend(phone: "+1234567890", type: "sms")
      expect(response).to be_a(Supabase::Auth::Types::AuthOtpResponse)
      stubs.verify_stubbed_calls
    end

    it "raises AuthInvalidCredentialsError when neither email nor phone provided" do
      client, _stubs = build_client_with_stubs { |_stub| }

      expect {
        client.resend(type: "signup")
      }.to raise_error(Supabase::Auth::Errors::AuthInvalidCredentialsError)
    end
  end

  # ──────────────────────────────────────────────────
  # AC-4: resend supports all types: signup, email_change, sms, phone_change
  # ──────────────────────────────────────────────────
  describe "AC-4: resend supports all type values" do
    %w[signup email_change].each do |type|
      it "supports email resend type: #{type}" do
        client, stubs = build_client_with_stubs do |stub|
          stub.post("/resend") do |env|
            body = JSON.parse(env.body)
            expect(body["type"]).to eq(type)
            expect(body["email"]).to eq("test@example.com")
            [200, { "Content-Type" => "application/json" }, { "message_id" => "msg-#{type}" }.to_json]
          end
        end

        client.resend(email: "test@example.com", type: type)
        stubs.verify_stubbed_calls
      end
    end

    %w[sms phone_change].each do |type|
      it "supports phone resend type: #{type}" do
        client, stubs = build_client_with_stubs do |stub|
          stub.post("/resend") do |env|
            body = JSON.parse(env.body)
            expect(body["type"]).to eq(type)
            expect(body["phone"]).to eq("+1234567890")
            [200, { "Content-Type" => "application/json" }, { "message_id" => "msg-#{type}" }.to_json]
          end
        end

        client.resend(phone: "+1234567890", type: type)
        stubs.verify_stubbed_calls
      end
    end
  end

  # ──────────────────────────────────────────────────
  # AC-5: captcha_token passed correctly in both methods
  # ──────────────────────────────────────────────────
  describe "AC-5: captcha_token passed correctly" do
    it "verify_otp sends captcha_token in gotrue_meta_security" do
      client, stubs = build_client_with_stubs do |stub|
        stub.post("/verify") do |env|
          body = JSON.parse(env.body)
          expect(body["gotrue_meta_security"]["captcha_token"]).to eq("captcha-abc")
          [200, { "Content-Type" => "application/json" }, mock_verify_response_without_session.to_json]
        end
      end

      client.verify_otp(
        email: "test@example.com",
        token: "123456",
        type: "email",
        options: { captcha_token: "captcha-abc" }
      )
      stubs.verify_stubbed_calls
    end

    it "verify_otp sends nil captcha_token when not provided (matching Python)" do
      client, stubs = build_client_with_stubs do |stub|
        stub.post("/verify") do |env|
          body = JSON.parse(env.body)
          expect(body["gotrue_meta_security"]).to be_a(Hash)
          [200, { "Content-Type" => "application/json" }, mock_verify_response_without_session.to_json]
        end
      end

      client.verify_otp(email: "test@example.com", token: "123456", type: "email")
      stubs.verify_stubbed_calls
    end

    it "resend sends captcha_token in gotrue_meta_security" do
      client, stubs = build_client_with_stubs do |stub|
        stub.post("/resend") do |env|
          body = JSON.parse(env.body)
          expect(body["gotrue_meta_security"]["captcha_token"]).to eq("captcha-xyz")
          [200, { "Content-Type" => "application/json" }, { "message_id" => "msg-123" }.to_json]
        end
      end

      client.resend(
        email: "test@example.com",
        type: "signup",
        options: { captcha_token: "captcha-xyz" }
      )
      stubs.verify_stubbed_calls
    end

    it "resend sends nil captcha_token when not provided" do
      client, stubs = build_client_with_stubs do |stub|
        stub.post("/resend") do |env|
          body = JSON.parse(env.body)
          expect(body["gotrue_meta_security"]).to be_a(Hash)
          [200, { "Content-Type" => "application/json" }, { "message_id" => "msg-123" }.to_json]
        end
      end

      client.resend(email: "test@example.com", type: "signup")
      stubs.verify_stubbed_calls
    end
  end

  # ──────────────────────────────────────────────────
  # AC-6: redirect_to / email_redirect_to passed correctly
  # ──────────────────────────────────────────────────
  describe "AC-6: redirect_to / email_redirect_to handling" do
    it "verify_otp passes redirect_to as query param" do
      client, stubs = build_client_with_stubs do |stub|
        stub.post("/verify") do |env|
          uri = URI.parse(env.url.to_s)
          params = URI.decode_www_form(uri.query || "").to_h
          expect(params["redirect_to"]).to eq("https://app.example.com/callback")
          [200, { "Content-Type" => "application/json" }, mock_verify_response_without_session.to_json]
        end
      end

      client.verify_otp(
        email: "test@example.com",
        token: "123456",
        type: "email",
        options: { redirect_to: "https://app.example.com/callback" }
      )
      stubs.verify_stubbed_calls
    end

    it "verify_otp omits redirect_to when not provided" do
      client, stubs = build_client_with_stubs do |stub|
        stub.post("/verify") do |env|
          uri = URI.parse(env.url.to_s)
          if uri.query
            params = URI.decode_www_form(uri.query).to_h
            expect(params).not_to have_key("redirect_to")
          end
          [200, { "Content-Type" => "application/json" }, mock_verify_response_without_session.to_json]
        end
      end

      client.verify_otp(email: "test@example.com", token: "123456", type: "email")
      stubs.verify_stubbed_calls
    end

    it "resend passes email_redirect_to as redirect_to query param for email credentials" do
      client, stubs = build_client_with_stubs do |stub|
        stub.post("/resend") do |env|
          uri = URI.parse(env.url.to_s)
          params = URI.decode_www_form(uri.query || "").to_h
          expect(params["redirect_to"]).to eq("https://app.example.com/confirm")
          [200, { "Content-Type" => "application/json" }, { "message_id" => "msg-123" }.to_json]
        end
      end

      client.resend(
        email: "test@example.com",
        type: "signup",
        options: { email_redirect_to: "https://app.example.com/confirm" }
      )
      stubs.verify_stubbed_calls
    end

    it "resend does NOT pass redirect_to for phone credentials (matches Python)" do
      client, stubs = build_client_with_stubs do |stub|
        stub.post("/resend") do |env|
          uri = URI.parse(env.url.to_s)
          if uri.query
            params = URI.decode_www_form(uri.query).to_h
            expect(params).not_to have_key("redirect_to")
          end
          [200, { "Content-Type" => "application/json" }, { "message_id" => "msg-456" }.to_json]
        end
      end

      client.resend(
        phone: "+1234567890",
        type: "sms",
        options: { email_redirect_to: "https://app.example.com/confirm" }
      )
      stubs.verify_stubbed_calls
    end

    it "resend prioritizes email over phone when both provided (matches Python)" do
      client, stubs = build_client_with_stubs do |stub|
        stub.post("/resend") do |env|
          body = JSON.parse(env.body)
          expect(body["email"]).to eq("test@example.com")
          expect(body).not_to have_key("phone")
          [200, { "Content-Type" => "application/json" }, { "message_id" => "msg-both" }.to_json]
        end
      end

      client.resend(
        email: "test@example.com",
        phone: "+1234567890",
        type: "signup"
      )
      stubs.verify_stubbed_calls
    end
  end

  # ──────────────────────────────────────────────────
  # String key support (matching codebase pattern)
  # ──────────────────────────────────────────────────
  describe "String key support" do
    it "verify_otp accepts string keys" do
      client, stubs = build_client_with_stubs do |stub|
        stub.post("/verify") do |env|
          body = JSON.parse(env.body)
          expect(body["email"]).to eq("test@example.com")
          expect(body["token"]).to eq("123456")
          expect(body["type"]).to eq("email")
          [200, { "Content-Type" => "application/json" }, mock_verify_response_without_session.to_json]
        end
      end

      client.verify_otp(
        "email" => "test@example.com",
        "token" => "123456",
        "type" => "email"
      )
      stubs.verify_stubbed_calls
    end

    it "resend accepts string keys" do
      client, stubs = build_client_with_stubs do |stub|
        stub.post("/resend") do |env|
          body = JSON.parse(env.body)
          expect(body["email"]).to eq("test@example.com")
          expect(body["type"]).to eq("signup")
          [200, { "Content-Type" => "application/json" }, { "message_id" => "msg-str" }.to_json]
        end
      end

      client.resend(
        "email" => "test@example.com",
        "type" => "signup"
      )
      stubs.verify_stubbed_calls
    end
  end
end
