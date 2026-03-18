# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

# US-015: Comprehensive audit findings tests
# Verifies each discrepancy/finding from the audit (US-001 through US-014),
# plus edge cases for expired sessions, network retries, PKCE flow, and MFA enrollment.
RSpec.describe "Audit Findings (US-015)" do
  let(:url) { "http://localhost:9999" }
  let(:headers) { { "apikey" => "test-api-key" } }

  let(:user_data) do
    {
      "id" => "user-123",
      "aud" => "authenticated",
      "role" => "authenticated",
      "email" => "test@example.com",
      "phone" => "+1234567890",
      "app_metadata" => { "provider" => "email" },
      "user_metadata" => { "name" => "Test" },
      "created_at" => "2024-01-01T00:00:00Z",
      "updated_at" => "2024-01-15T10:30:00Z"
    }
  end

  let(:session_data) do
    {
      "access_token" => "access-token-123",
      "refresh_token" => "refresh-token-123",
      "token_type" => "bearer",
      "expires_in" => 3600,
      "expires_at" => Time.now.to_i + 3600,
      "user" => user_data
    }
  end

  before { WebMock.disable_net_connect! }
  after { WebMock.allow_net_connect! }

  # ── US-001 FINDINGS: Client Authentication Methods ───────────────────

  describe "US-001: sign_up redirect_to / email_redirect_to fallback" do
    let(:client) { Supabase::Auth::Client.new(url: url, headers: headers, persist_session: false) }

    it "uses redirect_to from options" do
      allow(client).to receive(:_request).and_return(session_data)
      client.sign_up(email: "a@b.com", password: "pass123", options: { redirect_to: "https://app.com/cb" })

      expect(client).to have_received(:_request) do |_m, _p, **kwargs|
        expect(kwargs[:redirect_to]).to eq("https://app.com/cb")
      end
    end

    it "falls back to email_redirect_to when redirect_to is nil" do
      allow(client).to receive(:_request).and_return(session_data)
      client.sign_up(email: "a@b.com", password: "pass123", options: { email_redirect_to: "https://fallback.com" })

      expect(client).to have_received(:_request) do |_m, _p, **kwargs|
        expect(kwargs[:redirect_to]).to eq("https://fallback.com")
      end
    end

    it "includes gotrue_meta_security with captcha_token" do
      allow(client).to receive(:_request).and_return(session_data)
      client.sign_up(email: "a@b.com", password: "pass123", options: { captcha_token: "cap-tok" })

      expect(client).to have_received(:_request) do |_m, _p, **kwargs|
        expect(kwargs[:body][:gotrue_meta_security]).to eq({ captcha_token: "cap-tok" })
      end
    end

    it "includes channel parameter for phone signup (default sms)" do
      allow(client).to receive(:_request).and_return(session_data)
      client.sign_up(phone: "+1234567890", password: "pass123")

      expect(client).to have_received(:_request) do |_m, _p, **kwargs|
        expect(kwargs[:body][:channel]).to eq("sms")
        expect(kwargs[:body][:phone]).to eq("+1234567890")
        expect(kwargs[:body]).not_to have_key(:email)
      end
    end
  end

  # ── US-002 FINDINGS: Session Management ──────────────────────────────

  describe "US-002: get_session auto-refreshes within EXPIRY_MARGIN" do
    it "uses EXPIRY_MARGIN of 10 seconds" do
      expect(Supabase::Auth::Client::EXPIRY_MARGIN).to eq(10)
    end

    it "auto-refreshes session that expires within EXPIRY_MARGIN" do
      storage = Supabase::Auth::MemoryStorage.new
      almost_expired = session_data.merge("expires_at" => Time.now.to_i + 5) # within 10s margin
      storage.set_item("supabase.auth.token", JSON.generate(almost_expired))

      refreshed_data = session_data.merge("access_token" => "new-token", "expires_at" => Time.now.to_i + 3600)
      stub_request(:post, "#{url}/token?grant_type=refresh_token")
        .to_return(status: 200, body: refreshed_data.to_json,
                   headers: { "Content-Type" => "application/json" })

      client = Supabase::Auth::Client.new(url: url, headers: headers, storage: storage)
      session = client.get_session

      expect(session).to be_a(Supabase::Auth::Types::Session)
      expect(session.access_token).to eq("new-token")
    end

    it "returns session without refresh when not within EXPIRY_MARGIN" do
      storage = Supabase::Auth::MemoryStorage.new
      valid_session = session_data.merge("expires_at" => Time.now.to_i + 3600) # well beyond margin
      storage.set_item("supabase.auth.token", JSON.generate(valid_session))

      client = Supabase::Auth::Client.new(url: url, headers: headers, storage: storage)
      session = client.get_session

      expect(session.access_token).to eq("access-token-123")
    end
  end

  describe "US-002: sign_out scope handling" do
    it "defaults scope to 'global'" do
      storage = Supabase::Auth::MemoryStorage.new
      storage.set_item("supabase.auth.token", JSON.generate(session_data))
      client = Supabase::Auth::Client.new(url: url, headers: headers, storage: storage)
      client.initialize_from_storage

      stub_request(:post, "#{url}/logout?scope=global")
        .to_return(status: 204, body: "", headers: {})

      client.sign_out

      expect(WebMock).to have_requested(:post, "#{url}/logout?scope=global")
    end

    it "passes scope=others and preserves local session" do
      storage = Supabase::Auth::MemoryStorage.new
      storage.set_item("supabase.auth.token", JSON.generate(session_data))
      client = Supabase::Auth::Client.new(url: url, headers: headers, storage: storage)
      client.initialize_from_storage

      stub_request(:post, "#{url}/logout?scope=others")
        .to_return(status: 204, body: "", headers: {})

      events = []
      client.on_auth_state_change { |event, _s| events << event }
      client.sign_out(scope: "others")

      expect(WebMock).to have_requested(:post, "#{url}/logout?scope=others")
      # "others" scope should NOT remove local session or fire SIGNED_OUT
      expect(events).not_to include("SIGNED_OUT")
    end

    it "passes scope=local and removes local session" do
      storage = Supabase::Auth::MemoryStorage.new
      storage.set_item("supabase.auth.token", JSON.generate(session_data))
      client = Supabase::Auth::Client.new(url: url, headers: headers, storage: storage)
      client.initialize_from_storage

      stub_request(:post, "#{url}/logout?scope=local")
        .to_return(status: 204, body: "", headers: {})

      events = []
      client.on_auth_state_change { |event, _s| events << event }
      client.sign_out(scope: "local")

      expect(events).to include("SIGNED_OUT")
      expect(client.get_session).to be_nil
    end
  end

  describe "US-002: refresh_session sends grant_type=refresh_token" do
    let(:client) { Supabase::Auth::Client.new(url: url, headers: headers, persist_session: false) }

    it "sends POST to token with grant_type=refresh_token" do
      stub_request(:post, "#{url}/token?grant_type=refresh_token")
        .to_return(status: 200, body: session_data.to_json,
                   headers: { "Content-Type" => "application/json" })

      result = client.refresh_session("refresh-token-123")

      expect(result).to be_a(Supabase::Auth::Types::AuthResponse)
      expect(result.session.access_token).to eq("access-token-123")
      expect(WebMock).to have_requested(:post, "#{url}/token?grant_type=refresh_token")
    end

    it "raises AuthSessionMissing when no refresh token available" do
      expect { client.refresh_session }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end
  end

  describe "US-002: exchange_code_for_session PKCE flow" do
    let(:client) { Supabase::Auth::Client.new(url: url, headers: headers, persist_session: false) }

    it "sends correct body (auth_code, code_verifier) with grant_type=pkce" do
      allow(client).to receive(:_request).and_return(session_data)

      client.exchange_code_for_session(auth_code: "the-code", code_verifier: "the-verifier")

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("token")
        expect(kwargs[:params]).to eq({ "grant_type" => "pkce" })
        expect(kwargs[:body][:auth_code]).to eq("the-code")
        expect(kwargs[:body][:code_verifier]).to eq("the-verifier")
      end
    end
  end

  # ── US-003 FINDINGS: User Management Methods ─────────────────────────

  describe "US-003: get_user accepts optional JWT parameter" do
    let(:client) { Supabase::Auth::Client.new(url: url, headers: headers, persist_session: false) }

    it "uses provided JWT instead of session token" do
      stub_request(:get, "#{url}/user")
        .with(headers: { "Authorization" => "Bearer custom-jwt" })
        .to_return(status: 200, body: user_data.to_json,
                   headers: { "Content-Type" => "application/json" })

      result = client.get_user("custom-jwt")
      expect(result.user.email).to eq("test@example.com")
    end

    it "returns nil when no JWT and no session" do
      result = client.get_user
      expect(result).to be_nil
    end
  end

  describe "US-002: link_identity returns LinkIdentityResponse" do
    # Fixed: link_identity now returns LinkIdentityResponse (url only)
    # matching the return type from parse_link_identity_response
    let(:client) { Supabase::Auth::Client.new(url: url, headers: headers, persist_session: false) }

    it "returns LinkIdentityResponse with only url" do
      client.instance_variable_set(:@current_session,
        Supabase::Auth::Types::Session.new(
          access_token: "at", refresh_token: "rt", token_type: "bearer",
          expires_in: 3600, expires_at: Time.now.to_i + 3600
        ))

      stub_request(:get, %r{#{url}/user/identities/authorize})
        .to_return(status: 200, body: { "url" => "https://provider.com/auth" }.to_json,
                   headers: { "Content-Type" => "application/json" })

      result = client.link_identity(provider: "github")
      expect(result).to be_a(Supabase::Auth::Types::LinkIdentityResponse)
      expect(result.url).to eq("https://provider.com/auth")
    end
  end

  describe "US-003: unlink_identity uses identity_id field" do
    let(:client) { Supabase::Auth::Client.new(url: url, headers: headers, persist_session: false) }

    it "sends DELETE to user/identities/{identity_id}" do
      client.instance_variable_set(:@current_session,
        Supabase::Auth::Types::Session.new(
          access_token: "at", refresh_token: "rt", token_type: "bearer",
          expires_in: 3600, expires_at: Time.now.to_i + 3600
        ))

      stub_request(:delete, "#{url}/user/identities/identity-abc")
        .to_return(status: 200, body: "{}",
                   headers: { "Content-Type" => "application/json" })

      client.unlink_identity(Supabase::Auth::Types::Identity.new(identity_id: "identity-abc"))
      expect(WebMock).to have_requested(:delete, "#{url}/user/identities/identity-abc")
    end
  end

  describe "US-003: reset_password_for_email sends captcha_token and redirect_to" do
    let(:client) { Supabase::Auth::Client.new(url: url, headers: headers, persist_session: false) }

    it "sends correct body with captcha_token" do
      allow(client).to receive(:_request).and_return({})

      client.reset_password_for_email("user@test.com", captcha_token: "cap", redirect_to: "https://reset.com")

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("recover")
        expect(kwargs[:body][:email]).to eq("user@test.com")
        expect(kwargs[:body][:gotrue_meta_security]).to eq({ captcha_token: "cap" })
        expect(kwargs[:redirect_to]).to eq("https://reset.com")
      end
    end
  end

  describe "US-003: reauthenticate sends GET to /reauthenticate" do
    let(:client) { Supabase::Auth::Client.new(url: url, headers: headers, persist_session: false) }

    it "sends GET request with session JWT" do
      client.instance_variable_set(:@current_session,
        Supabase::Auth::Types::Session.new(
          access_token: "at", refresh_token: "rt", token_type: "bearer",
          expires_in: 3600, expires_at: Time.now.to_i + 3600
        ))

      allow(client).to receive(:_request).and_return({})

      client.reauthenticate

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("GET")
        expect(path).to eq("reauthenticate")
        expect(kwargs[:jwt]).to eq("at")
      end
    end
  end

  # ── US-004 FINDINGS: Admin API ───────────────────────────────────────

  describe "US-004: admin sign_out sends scope as query param (FINDING)" do
    # FINDING: Python uses jwt parameter auto-header; Ruby manually constructs
    # Authorization header via the jwt param in _request. Both achieve the same result.
    it "sends POST to /logout with scope query param and JWT header" do
      admin = Supabase::Auth::AdminApi.new(url: url, headers: headers)

      stub_request(:post, "#{url}/logout?scope=global")
        .with(headers: { "Authorization" => "Bearer admin-jwt" })
        .to_return(status: 204, body: "", headers: {})

      admin.sign_out("admin-jwt", "global")

      expect(WebMock).to have_requested(:post, "#{url}/logout?scope=global")
        .with(headers: { "Authorization" => "Bearer admin-jwt" })
    end

    it "sends scope=local when specified" do
      admin = Supabase::Auth::AdminApi.new(url: url, headers: headers)

      stub_request(:post, "#{url}/logout?scope=local")
        .to_return(status: 204, body: "", headers: {})

      admin.sign_out("jwt-token", "local")

      expect(WebMock).to have_requested(:post, "#{url}/logout?scope=local")
    end
  end

  # ── US-005 FINDINGS: MFA API Methods ─────────────────────────────────

  describe "US-005: MFA verify constructs specific fields (FINDING)" do
    # FINDING: Python passes full params dict, Ruby constructs specific fields
    let(:client) { Supabase::Auth::Client.new(url: url, headers: headers, persist_session: false) }

    it "sends factor_id, challenge_id, code to verify endpoint" do
      client.instance_variable_set(:@current_session,
        Supabase::Auth::Types::Session.new(
          access_token: "at", refresh_token: "rt", token_type: "bearer",
          expires_in: 3600, expires_at: Time.now.to_i + 3600
        ))

      allow(client).to receive(:_request).and_return(session_data)

      client.mfa.verify(factor_id: "fac-1", challenge_id: "chal-1", code: "123456")

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("factors/fac-1/verify")
        expect(kwargs[:body][:challenge_id]).to eq("chal-1")
        expect(kwargs[:body][:code]).to eq("123456")
      end
    end
  end

  describe "US-005: MFA list_factors categorizes into all/totp/phone" do
    let(:client) { Supabase::Auth::Client.new(url: url, headers: headers, persist_session: false) }

    it "returns AuthMFAListFactorsResponse with categorized factors" do
      client.instance_variable_set(:@current_session,
        Supabase::Auth::Types::Session.new(
          access_token: "at", refresh_token: "rt", token_type: "bearer",
          expires_in: 3600, expires_at: Time.now.to_i + 3600
        ))

      user_with_factors = user_data.merge(
        "factors" => [
          { "id" => "f1", "factor_type" => "totp", "status" => "verified",
            "created_at" => "2024-01-01T00:00:00Z", "updated_at" => "2024-01-01T00:00:00Z" },
          { "id" => "f2", "factor_type" => "phone", "status" => "verified",
            "created_at" => "2024-01-01T00:00:00Z", "updated_at" => "2024-01-01T00:00:00Z" }
        ]
      )

      stub_request(:get, "#{url}/user")
        .to_return(status: 200, body: user_with_factors.to_json,
                   headers: { "Content-Type" => "application/json" })

      result = client.mfa.list_factors

      expect(result).to be_a(Supabase::Auth::Types::AuthMFAListFactorsResponse)
      expect(result.all.length).to eq(2)
      expect(result.totp.length).to eq(1)
      expect(result.phone.length).to eq(1)
      expect(result.totp.first.factor_type).to eq("totp")
      expect(result.phone.first.factor_type).to eq("phone")
    end
  end

  describe "US-005: MFA enroll supports both totp and phone factor types" do
    let(:client) { Supabase::Auth::Client.new(url: url, headers: headers, persist_session: false) }

    before do
      client.instance_variable_set(:@current_session,
        Supabase::Auth::Types::Session.new(
          access_token: "at", refresh_token: "rt", token_type: "bearer",
          expires_in: 3600, expires_at: Time.now.to_i + 3600
        ))
    end

    it "sends correct body for TOTP enrollment" do
      allow(client).to receive(:_request).and_return(
        "id" => "f1", "type" => "totp", "friendly_name" => "My Auth",
        "totp" => { "qr_code" => "<svg/>", "secret" => "SECRET", "uri" => "otpauth://totp/..." }
      )

      result = client.mfa.enroll(factor_type: "totp", friendly_name: "My Auth")

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("factors")
        expect(kwargs[:body][:factor_type]).to eq("totp")
        expect(kwargs[:body][:friendly_name]).to eq("My Auth")
      end
      expect(result).to be_a(Supabase::Auth::Types::AuthMFAEnrollResponse)
      expect(result.type).to eq("totp")
    end

    it "sends correct body for phone enrollment with channel" do
      allow(client).to receive(:_request).and_return(
        "id" => "f2", "type" => "phone", "friendly_name" => "My Phone",
        "phone" => "+1234567890"
      )

      client.mfa.enroll(factor_type: "phone", phone: "+1234567890", friendly_name: "My Phone")

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("factors")
        expect(kwargs[:body][:factor_type]).to eq("phone")
        expect(kwargs[:body][:phone]).to eq("+1234567890")
      end
    end
  end

  describe "US-005: MFA challenge sends optional channel param" do
    let(:client) { Supabase::Auth::Client.new(url: url, headers: headers, persist_session: false) }

    it "includes channel in challenge body when provided" do
      client.instance_variable_set(:@current_session,
        Supabase::Auth::Types::Session.new(
          access_token: "at", refresh_token: "rt", token_type: "bearer",
          expires_in: 3600, expires_at: Time.now.to_i + 3600
        ))

      allow(client).to receive(:_request).and_return(
        "id" => "chal-1", "expires_at" => Time.now.to_i + 300, "type" => "phone"
      )

      client.mfa.challenge(factor_id: "fac-1", channel: "whatsapp")

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("factors/fac-1/challenge")
        expect(kwargs[:body][:channel]).to eq("whatsapp")
      end
    end
  end

  describe "US-005: MFA get_authenticator_assurance_level parses AMR entries" do
    let(:client) { Supabase::Auth::Client.new(url: url, headers: headers, persist_session: false) }

    it "determines aal1 when only password method present" do
      # Build a proper JWT with amr claim using HMAC
      payload = { "sub" => "user1", "exp" => Time.now.to_i + 3600, "aal" => "aal1",
                  "amr" => [{ "method" => "password", "timestamp" => Time.now.to_i }] }
      token = JWT.encode(payload, "test-secret", "HS256")

      session = Supabase::Auth::Types::Session.new(
        access_token: token, refresh_token: "rt", token_type: "bearer",
        expires_in: 3600, expires_at: Time.now.to_i + 3600,
        user: Supabase::Auth::Types::User.new(id: "u1", factors: [
          Supabase::Auth::Types::Factor.new(id: "f1", factor_type: "totp", status: "verified",
                                             created_at: Time.now, updated_at: Time.now)
        ])
      )
      client.instance_variable_set(:@current_session, session)

      result = client.mfa.get_authenticator_assurance_level

      expect(result).to be_a(Supabase::Auth::Types::AuthMFAGetAuthenticatorAssuranceLevelResponse)
      expect(result.current_level).to eq("aal1")
      expect(result.next_level).to eq("aal2")
      # AMR entries are raw hashes from the JWT payload
      expect(result.current_authentication_methods.first["method"]).to eq("password")
    end
  end

  # ── US-007 FINDINGS: Error Handling ──────────────────────────────────

  describe "US-007: AuthPKCEError exists in Ruby but not Python (FINDING)" do
    it "exists as a subclass of AuthError" do
      expect(Supabase::Auth::Errors::AuthPKCEError).to be < Supabase::Auth::Errors::AuthError
    end

    it "has status 400 and code pkce_error" do
      error = Supabase::Auth::Errors::AuthPKCEError.new("PKCE failure")
      expect(error.status).to eq(400)
      expect(error.code).to eq("pkce_error")
    end
  end

  describe "US-007: AuthRetryableError triggered on 502/503/504" do
    let(:api) { Supabase::Auth::Api.new(url: url, headers: headers) }

    [502, 503, 504].each do |status_code|
      it "raises AuthRetryableError on #{status_code}" do
        stub_request(:get, "#{url}/test")
          .to_return(status: status_code, body: "Error", headers: { "Content-Type" => "text/html" })

        expect { api.get("/test") }.to raise_error(Supabase::Auth::Errors::AuthRetryableError) do |e|
          expect(e.status).to eq(status_code)
        end
      end
    end
  end

  describe "US-007: error code extraction with API version header check" do
    it "uses 'code' field when X-Supabase-Api-Version >= 2024-01-01" do
      stub_request(:get, "#{url}/test")
        .to_return(status: 400,
                   body: '{"message":"Bad request","code":"invalid_credentials"}',
                   headers: { "Content-Type" => "application/json",
                              "X-Supabase-Api-Version" => "2024-01-01" })

      faraday = Faraday.new(url) { |f| f.response :raise_error }
      begin
        faraday.get("/test")
      rescue Faraday::ClientError => e
        result = Supabase::Auth::Helpers.handle_exception(e)
        expect(result.code).to eq("invalid_credentials")
      end
    end

    it "uses 'error_code' field when no API version header" do
      stub_request(:get, "#{url}/test")
        .to_return(status: 400,
                   body: '{"message":"Bad request","error_code":"validation_failed"}',
                   headers: { "Content-Type" => "application/json" })

      faraday = Faraday.new(url) { |f| f.response :raise_error }
      begin
        faraday.get("/test")
      rescue Faraday::ClientError => e
        result = Supabase::Auth::Helpers.handle_exception(e)
        expect(result.code).to eq("validation_failed")
      end
    end
  end

  # ── US-008 FINDINGS: Helper Functions ────────────────────────────────

  describe "US-008: parse_link_response separates link properties from user data (FINDING)" do
    # FINDING: Python uses dynamic model_dump filtering, Ruby uses hardcoded key list
    it "extracts action_link, email_otp, hashed_token, redirect_to, verification_type as properties" do
      data = {
        "action_link" => "https://auth.example.com/verify",
        "email_otp" => "123456",
        "hashed_token" => "hashed",
        "redirect_to" => "https://app.com",
        "verification_type" => "signup",
        "id" => "user-1",
        "email" => "test@example.com",
        "aud" => "authenticated"
      }
      result = Supabase::Auth::Helpers.parse_link_response(data)

      expect(result.properties.action_link).to eq("https://auth.example.com/verify")
      expect(result.properties.email_otp).to eq("123456")
      expect(result.properties.hashed_token).to eq("hashed")
      expect(result.properties.redirect_to).to eq("https://app.com")
      expect(result.properties.verification_type).to eq("signup")
      expect(result.user.id).to eq("user-1")
      expect(result.user.email).to eq("test@example.com")
    end
  end

  describe "US-008: get_error_message handles both dict and object attributes (FINDING)" do
    # FINDING: Python handles both dict and object attributes, Ruby now handles both
    it "extracts message from a Struct with message attribute" do
      obj = Struct.new(:message).new("object error message")
      result = Supabase::Auth::Helpers.send(:get_error_message, obj)
      expect(result).to eq("object error message")
    end

    it "extracts message from a Hash" do
      result = Supabase::Auth::Helpers.send(:get_error_message, { "message" => "hash error" })
      expect(result).to eq("hash error")
    end

    it "falls back to to_s for non-Hash without matching attributes" do
      result = Supabase::Auth::Helpers.send(:get_error_message, 42)
      expect(result).to eq("42")
    end
  end

  describe "US-008: PKCE helpers produce RFC 7636 compliant output" do
    it "generate_pkce_challenge uses S256 method (SHA256 + base64url, no padding)" do
      verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
      challenge = Supabase::Auth::Helpers.generate_pkce_challenge(verifier)
      expected = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
      expect(challenge).to eq(expected)
      expect(challenge).not_to include("=")
      expect(challenge).not_to include("+")
      expect(challenge).not_to include("/")
    end
  end

  # ── US-009 FINDINGS: HTTP Client / Base API ──────────────────────────

  describe "US-009: Content-Type and API version headers" do
    let(:api) { Supabase::Auth::Api.new(url: url, headers: headers) }

    it "sets Content-Type to application/json;charset=UTF-8" do
      stub_request(:post, "#{url}/test")
        .with(headers: { "Content-Type" => "application/json;charset=UTF-8" })
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      api.post("/test", body: {})
    end

    it "sends X-Supabase-Api-Version with value 2024-01-01" do
      stub_request(:get, "#{url}/test")
        .with(headers: { "X-Supabase-Api-Version" => "2024-01-01" })
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      api.get("/test")
    end

    it "adds Authorization Bearer when jwt parameter provided" do
      stub_request(:get, "#{url}/test")
        .with(headers: { "Authorization" => "Bearer my-token" })
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      api._request(:get, "/test", jwt: "my-token")
    end
  end

  describe "US-009: retry constants match Python" do
    it "MAX_RETRIES = 10" do
      expect(Supabase::Auth::Constants::MAX_RETRIES).to eq(10)
    end

    it "RETRY_INTERVAL = 2" do
      expect(Supabase::Auth::Constants::RETRY_INTERVAL).to eq(2)
    end
  end

  # ── US-010 FINDINGS: PKCE Flow ───────────────────────────────────────

  describe "US-010: PKCE verifier stored with correct key pattern" do
    let(:client) { Supabase::Auth::Client.new(url: url, persist_session: false) }

    it "stores verifier with key '{storage_key}-code-verifier'" do
      client._flow_type = "pkce"
      client._get_url_for_provider("#{url}/authorize", "github", {})

      stored = client._storage.get_item("#{client._storage_key}-code-verifier")
      expect(stored).not_to be_nil
      expect(stored.length).to eq(64) # default verifier length
    end

    it "cleans up verifier from storage after successful exchange" do
      storage_key = "#{client._storage_key}-code-verifier"
      client._storage.set_item(storage_key, "test-verifier")

      allow(client).to receive(:_request).and_return(session_data)
      client.exchange_code_for_session(auth_code: "code-1")

      expect(client._storage.get_item(storage_key)).to be_nil
    end
  end

  # ── US-013 FINDINGS: OTP Verify & Resend ─────────────────────────────

  describe "US-013: verify_otp handles all types" do
    let(:client) { Supabase::Auth::Client.new(url: url, headers: headers, persist_session: false) }

    it "sends email verification body" do
      allow(client).to receive(:_request).and_return(session_data)

      client.verify_otp(email: "a@b.com", token: "123456", type: "email")

      expect(client).to have_received(:_request) do |_m, path, **kwargs|
        expect(path).to eq("verify")
        expect(kwargs[:body][:email]).to eq("a@b.com")
        expect(kwargs[:body][:token]).to eq("123456")
        expect(kwargs[:body][:type]).to eq("email")
      end
    end

    it "sends phone verification body" do
      allow(client).to receive(:_request).and_return(session_data)

      client.verify_otp(phone: "+1234567890", token: "123456", type: "sms")

      expect(client).to have_received(:_request) do |_m, path, **kwargs|
        expect(path).to eq("verify")
        expect(kwargs[:body][:phone]).to eq("+1234567890")
        expect(kwargs[:body][:token]).to eq("123456")
        expect(kwargs[:body][:type]).to eq("sms")
      end
    end

    it "sends token_hash verification body" do
      allow(client).to receive(:_request).and_return(session_data)

      client.verify_otp(token_hash: "hash-abc", type: "email")

      expect(client).to have_received(:_request) do |_m, path, **kwargs|
        expect(path).to eq("verify")
        expect(kwargs[:body][:token_hash]).to eq("hash-abc")
        expect(kwargs[:body][:type]).to eq("email")
      end
    end

    it "includes captcha_token in gotrue_meta_security" do
      allow(client).to receive(:_request).and_return(session_data)

      client.verify_otp(email: "a@b.com", token: "123456", type: "email",
                        options: { captcha_token: "cap-tok" })

      expect(client).to have_received(:_request) do |_m, _path, **kwargs|
        expect(kwargs[:body][:gotrue_meta_security]).to eq({ captcha_token: "cap-tok" })
      end
    end
  end

  describe "US-013: resend sends correct body" do
    let(:client) { Supabase::Auth::Client.new(url: url, headers: headers, persist_session: false) }

    it "sends email resend with type and email_redirect_to" do
      allow(client).to receive(:_request).and_return({})

      client.resend(email: "a@b.com", type: "signup",
                    options: { captcha_token: "cap", email_redirect_to: "https://app.com" })

      expect(client).to have_received(:_request) do |_m, path, **kwargs|
        expect(path).to eq("resend")
        expect(kwargs[:body][:email]).to eq("a@b.com")
        expect(kwargs[:body][:type]).to eq("signup")
        expect(kwargs[:body][:gotrue_meta_security]).to eq({ captcha_token: "cap" })
        expect(kwargs[:redirect_to]).to eq("https://app.com")
      end
    end

    it "sends phone resend" do
      allow(client).to receive(:_request).and_return({})

      client.resend(phone: "+1234567890", type: "sms")

      expect(client).to have_received(:_request) do |_m, path, **kwargs|
        expect(path).to eq("resend")
        expect(kwargs[:body][:phone]).to eq("+1234567890")
        expect(kwargs[:body][:type]).to eq("sms")
        expect(kwargs[:body]).not_to have_key(:email)
      end
    end

    it "raises AuthInvalidCredentialsError when neither email nor phone provided" do
      expect {
        client.resend(type: "signup")
      }.to raise_error(Supabase::Auth::Errors::AuthInvalidCredentialsError)
    end
  end

  # ── US-014 FINDINGS: Initialization Flow ─────────────────────────────

  describe "US-014: default options match Python" do
    subject(:client) { Supabase::Auth::Client.new(url: url) }

    it "defaults flow_type to 'implicit'" do
      expect(client._flow_type).to eq("implicit")
    end

    it "defaults storage_key to 'supabase.auth.token'" do
      expect(client._storage_key).to eq("supabase.auth.token")
    end

    it "DEFAULT_OPTIONS matches Python defaults" do
      defaults = Supabase::Auth::Client::DEFAULT_OPTIONS
      expect(defaults[:auto_refresh_token]).to be true
      expect(defaults[:persist_session]).to be true
      expect(defaults[:detect_session_in_url]).to be true
      expect(defaults[:flow_type]).to eq("implicit")
    end

    it "STORAGE_KEY constant is 'supabase.auth.token'" do
      expect(Supabase::Auth::Client::STORAGE_KEY).to eq("supabase.auth.token")
    end
  end

  # ── EDGE CASES ───────────────────────────────────────────────────────

  describe "Edge case: expired session recovery from storage" do
    it "attempts refresh for expired session and emits TOKEN_REFRESHED" do
      storage = Supabase::Auth::MemoryStorage.new
      expired_session = session_data.merge("expires_at" => Time.now.to_i - 100)
      storage.set_item("supabase.auth.token", JSON.generate(expired_session))

      refreshed = session_data.merge("access_token" => "refreshed-token", "expires_at" => Time.now.to_i + 3600)
      stub_request(:post, "#{url}/token?grant_type=refresh_token")
        .to_return(status: 200, body: refreshed.to_json,
                   headers: { "Content-Type" => "application/json" })

      events = []
      client = Supabase::Auth::Client.new(url: url, headers: headers, storage: storage, auto_refresh_token: true)
      client.on_auth_state_change { |event, _s| events << event }
      client.initialize_from_storage

      expect(WebMock).to have_requested(:post, "#{url}/token?grant_type=refresh_token")
      expect(events).to include("TOKEN_REFRESHED")
    end

    it "removes session when refresh fails with non-retryable error" do
      storage = Supabase::Auth::MemoryStorage.new
      expired_session = session_data.merge("expires_at" => Time.now.to_i - 100)
      storage.set_item("supabase.auth.token", JSON.generate(expired_session))

      stub_request(:post, "#{url}/token?grant_type=refresh_token")
        .to_return(status: 401,
                   body: '{"error":"invalid_grant","error_description":"Invalid refresh token"}',
                   headers: { "Content-Type" => "application/json" })

      client = Supabase::Auth::Client.new(url: url, headers: headers, storage: storage, auto_refresh_token: true)
      client.initialize_from_storage

      expect(storage.get_item("supabase.auth.token")).to be_nil
    end
  end

  describe "Edge case: session storage validation" do
    it "rejects session with invalid JSON" do
      storage = Supabase::Auth::MemoryStorage.new
      storage.set_item("supabase.auth.token", "not-json{{{")

      client = Supabase::Auth::Client.new(url: url, headers: headers, storage: storage)
      client.initialize_from_storage

      expect(storage.get_item("supabase.auth.token")).to be_nil
    end

    it "rejects session missing access_token" do
      storage = Supabase::Auth::MemoryStorage.new
      storage.set_item("supabase.auth.token", JSON.generate({ "refresh_token" => "rt", "expires_at" => Time.now.to_i + 3600 }))

      client = Supabase::Auth::Client.new(url: url, headers: headers, storage: storage)
      client.initialize_from_storage

      expect(storage.get_item("supabase.auth.token")).to be_nil
    end

    it "rejects session missing refresh_token" do
      storage = Supabase::Auth::MemoryStorage.new
      storage.set_item("supabase.auth.token", JSON.generate({ "access_token" => "at", "expires_at" => Time.now.to_i + 3600 }))

      client = Supabase::Auth::Client.new(url: url, headers: headers, storage: storage)
      client.initialize_from_storage

      expect(storage.get_item("supabase.auth.token")).to be_nil
    end

    it "rejects session with non-integer expires_at" do
      storage = Supabase::Auth::MemoryStorage.new
      storage.set_item("supabase.auth.token", JSON.generate({ "access_token" => "at", "refresh_token" => "rt", "expires_at" => "invalid" }))

      client = Supabase::Auth::Client.new(url: url, headers: headers, storage: storage)
      client.initialize_from_storage

      expect(storage.get_item("supabase.auth.token")).to be_nil
    end
  end

  describe "Edge case: set_session with expired access token" do
    let(:client) { Supabase::Auth::Client.new(url: url, headers: headers, persist_session: false) }

    it "refreshes when access token is expired" do
      expired_payload = { "sub" => "user1", "exp" => Time.now.to_i - 100 }
      header = Base64.urlsafe_encode64(JSON.generate({ "alg" => "HS256", "typ" => "JWT" }), padding: false)
      body = Base64.urlsafe_encode64(JSON.generate(expired_payload), padding: false)
      expired_token = "#{header}.#{body}.fake"

      stub_request(:post, "#{url}/token?grant_type=refresh_token")
        .to_return(status: 200, body: session_data.to_json,
                   headers: { "Content-Type" => "application/json" })

      result = client.set_session(expired_token, "refresh-token")
      expect(result).to be_a(Supabase::Auth::Types::AuthResponse)
    end

    it "raises AuthSessionMissing when expired and no refresh token" do
      expired_payload = { "sub" => "user1", "exp" => Time.now.to_i - 100 }
      header = Base64.urlsafe_encode64(JSON.generate({ "alg" => "HS256", "typ" => "JWT" }), padding: false)
      body = Base64.urlsafe_encode64(JSON.generate(expired_payload), padding: false)
      expired_token = "#{header}.#{body}.fake"

      expect {
        client.set_session(expired_token, "")
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end
  end

  describe "Edge case: API response body parsing" do
    let(:api) { Supabase::Auth::Api.new(url: url, headers: headers) }

    it "returns empty hash for empty response body (204 No Content)" do
      stub_request(:post, "#{url}/logout")
        .to_return(status: 204, body: nil, headers: {})

      result = api.post("/logout", body: {})
      expect(result).to eq({})
    end

    it "returns empty hash for non-JSON response" do
      stub_request(:get, "#{url}/health")
        .to_return(status: 200, body: "OK", headers: { "Content-Type" => "text/plain" })

      result = api.get("/health")
      expect(result).to eq({})
    end
  end

  describe "Edge case: MemoryStorage operations" do
    let(:storage) { Supabase::Auth::MemoryStorage.new }

    it "set_item / get_item / remove_item work correctly" do
      storage.set_item("key1", "value1")
      expect(storage.get_item("key1")).to eq("value1")

      storage.remove_item("key1")
      expect(storage.get_item("key1")).to be_nil
    end

    it "get_item returns nil for non-existent key" do
      expect(storage.get_item("nonexistent")).to be_nil
    end
  end

  describe "Edge case: sign_in_with_sso requires domain or provider_id" do
    let(:client) { Supabase::Auth::Client.new(url: url, headers: headers, persist_session: false) }

    it "raises AuthInvalidCredentialsError when neither provided" do
      expect {
        client.sign_in_with_sso({})
      }.to raise_error(Supabase::Auth::Errors::AuthInvalidCredentialsError, /domain or provider_id/)
    end
  end

  describe "Edge case: sign_in_with_oauth constructs correct URL" do
    let(:client) { Supabase::Auth::Client.new(url: url, headers: headers, persist_session: false) }

    it "returns OAuthResponse with provider and constructed URL" do
      result = client.sign_in_with_oauth(provider: "github", options: { redirect_to: "https://app.com/cb" })

      expect(result).to be_a(Supabase::Auth::Types::OAuthResponse)
      expect(result.provider).to eq("github")
      expect(result.url).to include("authorize")
      expect(result.url).to include("provider=github")
      expect(result.url).to include("redirect_to=")
    end
  end
end
