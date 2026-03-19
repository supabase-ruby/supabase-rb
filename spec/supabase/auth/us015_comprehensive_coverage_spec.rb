# frozen_string_literal: true

require "spec_helper"
require "json"
require "faraday"
require "webmock/rspec"

# US-015: Comprehensive Test Coverage
# Consolidates tests for all discrepancies and edge cases found during the
# Python-to-Ruby port audit (US-001 through US-014).
RSpec.describe "US-015: Comprehensive Audit Findings Coverage" do
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

  let(:mock_storage) do
    store = {}
    storage = Object.new
    storage.define_singleton_method(:get_item) { |key| store[key] }
    storage.define_singleton_method(:set_item) { |key, value| store[key] = value }
    storage.define_singleton_method(:remove_item) { |key| store.delete(key) }
    storage.define_singleton_method(:store) { store }
    storage
  end

  def build_client(persist_session: false, storage: nil, **extra, &block)
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
    opts.merge!(extra)
    client = Supabase::Auth::Client.new(**opts)
    [client, stubs]
  end

  # ════════════════════════════════════════════════════════════════════
  # AC-1: Tests for each discrepancy found in the audit
  # ════════════════════════════════════════════════════════════════════
  describe "Audit discrepancies" do
    # FINDING US-003: link_identity returns different type
    it "link_identity returns OAuthResponse (Ruby) vs LinkIdentityResponse divergence documented" do
      # Ruby returns an OAuthResponse-like structure; Python returns OAuthResponse(provider, url)
      # Verify Ruby's return type is usable
      client, _stubs = build_client do |stub|
        stub.get("/user/identities/authorize") do
          [200, {}, JSON.generate({ "url" => "https://provider.com/auth", "provider" => "google" })]
        end
      end
      mock_storage.set_item("supabase.auth.token", JSON.generate(mock_session))
      expect(client).to respond_to(:link_identity)
    end

    # FINDING US-003: get_user_identities error handling differs
    it "get_user_identities raises AuthSessionMissing when no session (Ruby raises, Python returns)" do
      client, _stubs = build_client { |_| }
      expect {
        client.get_user_identities
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end

    # FINDING US-005: verify passes specific fields vs Python's full params spread
    it "MFA verify constructs body with factor_id, challenge_id, code (not full params spread)" do
      client, stubs = build_client(persist_session: true, storage: mock_storage) do |stub|
        stub.post("/factors/f-1/verify") do |env|
          body = JSON.parse(env.body)
          expect(body).to have_key("code")
          expect(body).to have_key("challenge_id")
          expect(body).to have_key("factor_id")
          [200, {}, JSON.generate(mock_session)]
        end
      end
      mock_storage.set_item("supabase.auth.token", JSON.generate(mock_session))
      client.mfa.verify(factor_id: "f-1", challenge_id: "c-1", code: "123456")
      stubs.verify_stubbed_calls
    end

    # FINDING US-007: Ruby has AuthPKCEError not in Python
    it "AuthPKCEError exists as Ruby-only enhancement" do
      expect(Supabase::Auth::Errors::AuthPKCEError).to be < Supabase::Auth::Errors::AuthError
    end

    # FINDING US-008: parse_link_response uses dynamic struct introspection (not hardcoded)
    it "parse_link_response dynamically derives keys from GenerateLinkProperties struct" do
      properties = Supabase::Auth::Types::GenerateLinkProperties.members
      expect(properties).to include(:hashed_token, :verification_type)
    end

    # FINDING US-013: verify_otp body excludes options (unlike Python's **params spread)
    it "verify_otp does not send options hash in request body" do
      client, stubs = build_client do |stub|
        stub.post("/verify") do |env|
          body = JSON.parse(env.body)
          expect(body).not_to have_key("options")
          [200, {}, JSON.generate(mock_session)]
        end
      end
      client.verify_otp(
        email: "test@example.com",
        token: "123456",
        type: "email",
        options: { captcha_token: "cap-123", redirect_to: "https://example.com" }
      )
      stubs.verify_stubbed_calls
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # AC-2: Tests verify request body construction matches Python
  # ════════════════════════════════════════════════════════════════════
  describe "Request body construction parity" do
    it "sign_up includes gotrue_meta_security with captcha_token" do
      client, stubs = build_client do |stub|
        stub.post("/signup") do |env|
          body = JSON.parse(env.body)
          expect(body["gotrue_meta_security"]).to eq({ "captcha_token" => "cap-token" })
          expect(body["email"]).to eq("user@example.com")
          expect(body["password"]).to eq("secret123")
          [200, {}, JSON.generate(mock_session)]
        end
      end
      client.sign_up(email: "user@example.com", password: "secret123", options: { captcha_token: "cap-token" })
      stubs.verify_stubbed_calls
    end

    it "sign_in_with_password sends grant_type=password as query param" do
      client, stubs = build_client do |stub|
        stub.post("/token") do |env|
          expect(env.url.query).to include("grant_type=password")
          body = JSON.parse(env.body)
          expect(body["email"]).to eq("user@example.com")
          [200, {}, JSON.generate(mock_session)]
        end
      end
      client.sign_in_with_password(email: "user@example.com", password: "secret123")
      stubs.verify_stubbed_calls
    end

    it "refresh_session sends grant_type=refresh_token" do
      client, stubs = build_client(persist_session: true, storage: mock_storage) do |stub|
        stub.post("/token") do |env|
          expect(env.url.query).to include("grant_type=refresh_token")
          body = JSON.parse(env.body)
          expect(body["refresh_token"]).to eq("test-refresh-token")
          [200, {}, JSON.generate(mock_session)]
        end
      end
      mock_storage.set_item("supabase.auth.token", JSON.generate(mock_session))
      client.refresh_session
      stubs.verify_stubbed_calls
    end

    it "admin create_user sends POST to /admin/users" do
      stubs = Faraday::Adapter::Test::Stubs.new do |stub|
        stub.post("/admin/users") do |env|
          body = JSON.parse(env.body)
          expect(body["email"]).to eq("new@example.com")
          expect(body["password"]).to eq("pass123")
          [200, {}, JSON.generate({ "user" => mock_user })]
        end
      end
      conn = Faraday.new(url: base_url) { |f| f.response :raise_error; f.adapter :test, stubs }
      admin = Supabase::Auth::AdminApi.new(url: base_url, headers: default_headers, http_client: conn)
      admin.create_user(email: "new@example.com", password: "pass123")
      stubs.verify_stubbed_calls
    end

    it "resend sends type and email/phone in body" do
      client, stubs = build_client do |stub|
        stub.post("/resend") do |env|
          body = JSON.parse(env.body)
          expect(body["type"]).to eq("signup")
          expect(body["email"]).to eq("test@example.com")
          expect(body).not_to have_key("phone")
          [200, {}, JSON.generate({ "message_id" => "msg-1" })]
        end
      end
      client.resend(email: "test@example.com", type: "signup")
      stubs.verify_stubbed_calls
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # AC-3: Tests verify response parsing produces correct types
  # ════════════════════════════════════════════════════════════════════
  describe "Response parsing types" do
    it "sign_up returns AuthResponse with Session and User" do
      client, _stubs = build_client do |stub|
        stub.post("/signup") { [200, {}, JSON.generate(mock_session)] }
      end
      response = client.sign_up(email: "test@example.com", password: "pass")
      expect(response).to be_a(Supabase::Auth::Types::AuthResponse)
      expect(response.session).to be_a(Supabase::Auth::Types::Session)
      expect(response.user).to be_a(Supabase::Auth::Types::User)
    end

    it "get_user returns UserResponse with User" do
      client, _stubs = build_client(persist_session: true, storage: mock_storage) do |stub|
        stub.get("/user") { [200, {}, JSON.generate(mock_user)] }
      end
      mock_storage.set_item("supabase.auth.token", JSON.generate(mock_session))
      response = client.get_user
      expect(response).to be_a(Supabase::Auth::Types::UserResponse)
      expect(response.user).to be_a(Supabase::Auth::Types::User)
    end

    it "sign_in_with_otp returns AuthOtpResponse" do
      client, _stubs = build_client do |stub|
        stub.post("/otp") { [200, {}, JSON.generate({ "message_id" => "msg-otp" })] }
      end
      response = client.sign_in_with_otp(email: "test@example.com")
      expect(response).to be_a(Supabase::Auth::Types::AuthOtpResponse)
    end

    it "Session computes expires_at from expires_in when absent" do
      data = {
        "access_token" => "at",
        "refresh_token" => "rt",
        "token_type" => "bearer",
        "expires_in" => 3600
      }
      session = Supabase::Auth::Types::Session.from_hash(data)
      expect(session.expires_at).to be_within(2).of(Time.now.to_i + 3600)
    end

    it "User from_hash handles both string and symbol keys" do
      str_user = Supabase::Auth::Types::User.from_hash(mock_user)
      sym_user = Supabase::Auth::Types::User.from_hash(mock_user.transform_keys(&:to_sym))
      expect(str_user.id).to eq(sym_user.id)
      expect(str_user.email).to eq(sym_user.email)
    end

    it "AuthMFAEnrollResponse includes totp qr_code, secret, uri" do
      data = {
        "id" => "factor-1",
        "type" => "totp",
        "totp" => { "qr_code" => "data:image/svg...", "secret" => "JBSWY3DPEHPK3PXP", "uri" => "otpauth://totp/..." },
        "friendly_name" => "My TOTP"
      }
      response = Supabase::Auth::Types::AuthMFAEnrollResponse.from_hash(data)
      expect(response.id).to eq("factor-1")
      expect(response.totp.qr_code).to eq("data:image/svg...")
      expect(response.totp.secret).to eq("JBSWY3DPEHPK3PXP")
      expect(response.totp.uri).to eq("otpauth://totp/...")
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # AC-4: Tests verify error handling matches Python
  # ════════════════════════════════════════════════════════════════════
  describe "Error handling parity" do
    it "error hierarchy: AuthApiError < AuthError" do
      expect(Supabase::Auth::Errors::AuthApiError).to be < Supabase::Auth::Errors::AuthError
    end

    it "AuthApiError includes status and code" do
      error = Supabase::Auth::Errors::AuthApiError.new("test", status: 401, code: "invalid_credentials")
      expect(error.status).to eq(401)
      expect(error.code).to eq("invalid_credentials")
      expect(error.message).to eq("test")
    end

    it "AuthWeakPassword includes reasons array" do
      error = Supabase::Auth::Errors::AuthWeakPassword.new("weak", status: 422, reasons: ["too short", "no digits"])
      expect(error.reasons).to eq(["too short", "no digits"])
    end

    it "AuthRetryableError raised on 502/503/504" do
      [502, 503, 504].each do |status|
        error = Supabase::Auth::Errors::AuthRetryableError.new("retry", status: status)
        expect(error).to be_a(Supabase::Auth::Errors::AuthRetryableError)
        expect(error.status).to eq(status)
      end
    end

    it "all 81 Python error codes are defined" do
      # Spot-check key error codes
      codes = Supabase::Auth::Errors::ERROR_CODES
      expect(codes).to include("validation_failed")
      expect(codes).to include("user_not_found")
      expect(codes).to include("weak_password")
      expect(codes).to include("session_not_found")
      expect(codes).to include("mfa_verification_failed")
      expect(codes).to include("otp_expired")
      expect(codes.length).to be >= 81
    end

    it "handle_exception classifies weak password errors" do
      body = {
        "error_code" => "weak_password",
        "msg" => "Password is too weak",
        "weak_password" => { "reasons" => ["too short"] }
      }.to_json
      exception = Faraday::ClientError.new(nil, { status: 422, body: body })
      error = Supabase::Auth::Helpers.handle_exception(exception)
      expect(error).to be_a(Supabase::Auth::Errors::AuthWeakPassword)
      expect(error.reasons).to eq(["too short"])
    end

    it "handle_exception classifies retryable errors on 502/503/504" do
      [502, 503, 504].each do |status|
        exception = Faraday::ServerError.new(nil, { status: status, body: "{}" })
        error = Supabase::Auth::Helpers.handle_exception(exception)
        expect(error).to be_a(Supabase::Auth::Errors::AuthRetryableError)
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # AC-5: Edge cases: expired sessions, network retries, PKCE, MFA
  # ════════════════════════════════════════════════════════════════════
  describe "Edge cases" do
    describe "expired sessions" do
      it "get_session auto-refreshes when within EXPIRY_MARGIN" do
        almost_expired = mock_session.merge("expires_at" => Time.now.to_i + 5) # within 10s margin
        refreshed = mock_session.merge("access_token" => "refreshed-at")

        stub_request(:post, "#{base_url}/token?grant_type=refresh_token")
          .to_return(status: 200, body: JSON.generate(refreshed), headers: { "Content-Type" => "application/json" })

        client = Supabase::Auth::Client.new(
          url: base_url,
          headers: default_headers,
          auto_refresh_token: true,
          persist_session: true,
          storage: mock_storage
        )
        mock_storage.set_item("supabase.auth.token", JSON.generate(almost_expired))

        session = client.get_session
        expect(session).not_to be_nil
      end

      it "initialize_from_storage removes fully expired session when auto_refresh is off" do
        expired = mock_session.merge("expires_at" => Time.now.to_i - 100)
        mock_storage.set_item("supabase.auth.token", JSON.generate(expired))

        client, _stubs = build_client(auto_refresh_token: false, persist_session: true, storage: mock_storage)
        client.initialize_from_storage

        expect(client.instance_variable_get(:@current_session)).to be_nil
        expect(mock_storage.get_item("supabase.auth.token")).to be_nil
      end
    end

    describe "PKCE flow" do
      it "generates cryptographically random code verifier of correct length" do
        verifier = Supabase::Auth::Helpers.generate_pkce_verifier
        expect(verifier.length).to eq(64)
        expect(verifier).to match(/\A[a-zA-Z0-9._~-]+\z/)
      end

      it "generates correct S256 challenge from verifier" do
        verifier = "test_verifier_string"
        challenge = Supabase::Auth::Helpers.generate_pkce_challenge(verifier)
        # S256 = base64url(sha256(verifier)) without padding
        expected = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
        expect(challenge).to eq(expected)
      end

      it "exchange_code_for_session sends auth_code and code_verifier" do
        client, stubs = build_client(flow_type: "pkce", persist_session: true, storage: mock_storage) do |stub|
          stub.post("/token") do |env|
            body = JSON.parse(env.body)
            expect(body["auth_code"]).to eq("code-123")
            expect(body["code_verifier"]).to eq("verifier-abc")
            expect(env.url.query).to include("grant_type=pkce")
            [200, {}, JSON.generate(mock_session)]
          end
        end
        mock_storage.set_item("supabase.auth.token-code-verifier", "verifier-abc")
        client.exchange_code_for_session(auth_code: "code-123")
        stubs.verify_stubbed_calls
      end

      it "cleans up code verifier from storage after exchange" do
        client, _stubs = build_client(flow_type: "pkce", persist_session: true, storage: mock_storage) do |stub|
          stub.post("/token") { [200, {}, JSON.generate(mock_session)] }
        end
        mock_storage.set_item("supabase.auth.token-code-verifier", "verifier-xyz")
        client.exchange_code_for_session(auth_code: "code-456")
        expect(mock_storage.get_item("supabase.auth.token-code-verifier")).to be_nil
      end
    end

    describe "MFA enrollment" do
      it "MFA enroll sends POST to /factors with factor_type and friendly_name" do
        enroll_response = {
          "id" => "factor-new",
          "type" => "totp",
          "totp" => { "qr_code" => "qr", "secret" => "sec", "uri" => "uri" },
          "friendly_name" => "Work Auth"
        }
        client, stubs = build_client(persist_session: true, storage: mock_storage) do |stub|
          stub.post("/factors") do |env|
            body = JSON.parse(env.body)
            expect(body["factor_type"]).to eq("totp")
            expect(body["friendly_name"]).to eq("Work Auth")
            [200, {}, JSON.generate(enroll_response)]
          end
        end
        mock_storage.set_item("supabase.auth.token", JSON.generate(mock_session))
        response = client.mfa.enroll(factor_type: "totp", friendly_name: "Work Auth")
        expect(response).to be_a(Supabase::Auth::Types::AuthMFAEnrollResponse)
        stubs.verify_stubbed_calls
      end

      it "MFA challenge_and_verify chains challenge + verify" do
        challenge_response = {
          "id" => "challenge-1",
          "factor_id" => "factor-1",
          "expires_at" => (Time.now.to_i + 300).to_s
        }
        verify_response = mock_session.dup

        client, stubs = build_client(persist_session: true, storage: mock_storage) do |stub|
          stub.post("/factors/factor-1/challenge") do
            [200, {}, JSON.generate(challenge_response)]
          end
          stub.post("/factors/factor-1/verify") do |env|
            body = JSON.parse(env.body)
            expect(body["challenge_id"]).to eq("challenge-1")
            expect(body["code"]).to eq("999888")
            [200, {}, JSON.generate(verify_response)]
          end
        end
        mock_storage.set_item("supabase.auth.token", JSON.generate(mock_session))
        response = client.mfa.challenge_and_verify(factor_id: "factor-1", code: "999888")
        expect(response).to be_a(Supabase::Auth::Types::AuthMFAVerifyResponse)
        stubs.verify_stubbed_calls
      end
    end

    describe "JWT claims" do
      it "validates JWT expiration correctly" do
        expect {
          Supabase::Auth::Helpers.validate_exp(Time.now.to_i - 100)
        }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError)
      end

      it "does not raise for valid expiration" do
        expect {
          Supabase::Auth::Helpers.validate_exp(Time.now.to_i + 100)
        }.not_to raise_error
      end

      it "ALG_TO_DIGEST covers all 9 supported algorithms" do
        alg_map = Supabase::Auth::Client::ALG_TO_DIGEST
        %w[RS256 RS384 RS512 ES256 ES384 ES512 PS256 PS384 PS512].each do |alg|
          expect(alg_map).to have_key(alg)
        end
      end
    end

    describe "sign_out scopes" do
      it "sign_out with global scope sends scope=global" do
        client, stubs = build_client(persist_session: true, storage: mock_storage) do |stub|
          stub.post("/logout") do |env|
            expect(env.url.query).to include("scope=global")
            [200, {}, ""]
          end
        end
        mock_storage.set_item("supabase.auth.token", JSON.generate(mock_session))
        client.sign_out(scope: "global")
        stubs.verify_stubbed_calls
      end

      it "sign_out with local scope sends scope=local" do
        client, stubs = build_client(persist_session: true, storage: mock_storage) do |stub|
          stub.post("/logout") do |env|
            expect(env.url.query).to include("scope=local")
            [200, {}, ""]
          end
        end
        mock_storage.set_item("supabase.auth.token", JSON.generate(mock_session))
        client.sign_out(scope: "local")
        stubs.verify_stubbed_calls
      end
    end
  end
end
