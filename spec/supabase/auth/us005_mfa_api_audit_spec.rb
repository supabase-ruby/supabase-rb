# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "json"
require "jwt"

# US-005: Audit MFA API Methods
# Verifies that Ruby MFA API methods match Python behavior:
#   - enroll supports both totp and phone factor types
#   - challenge sends correct body with optional channel param
#   - verify sends factor_id, challenge_id, code
#   - challenge_and_verify chains challenge + verify correctly
#   - unenroll sends DELETE to /factors/{factor_id}
#   - list_factors categorizes factors into all/totp/phone
#   - get_authenticator_assurance_level correctly parses AMR entries and determines AAL levels
RSpec.describe "US-005: MFA API Methods Audit" do
  let(:base_url) { "http://localhost:9998" }

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
      updated_at: Time.parse("2023-01-01T00:00:00Z"),
      factors: []
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

  let(:client) do
    Supabase::Auth::Client.new(
      url: base_url,
      auto_refresh_token: false,
      persist_session: false
    )
  end

  def setup_session(client, session)
    client.instance_variable_set(:@current_session, session)
  end

  before do
    WebMock.disable_net_connect!
  end

  after do
    WebMock.allow_net_connect!
  end

  # ── AC-1: enroll supports both totp and phone factor types ──

  describe "AC-1: enroll supports both totp and phone factor types" do
    it "sends POST to /factors with totp factor_type, friendly_name, and issuer" do
      setup_session(client, mock_session)

      stub = stub_request(:post, "#{base_url}/factors")
        .with(
          body: hash_including("factor_type" => "totp", "friendly_name" => "my-totp", "issuer" => "MyApp"),
          headers: { "Authorization" => "Bearer mock-access-token" }
        )
        .to_return(
          status: 200,
          body: {
            "id" => "factor-1", "type" => "totp", "friendly_name" => "my-totp",
            "totp" => { "qr_code" => "<svg>qr</svg>", "secret" => "JBSWY3DPEHPK3PXP",
                        "uri" => "otpauth://totp/MyApp?secret=JBSWY3DPEHPK3PXP" }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      response = client.mfa.enroll(factor_type: "totp", friendly_name: "my-totp", issuer: "MyApp")

      expect(stub).to have_been_requested
      expect(response).to be_a(Supabase::Auth::Types::AuthMFAEnrollResponse)
      expect(response.id).to eq("factor-1")
      expect(response.type).to eq("totp")
      expect(response.friendly_name).to eq("my-totp")
    end

    it "sends POST to /factors with phone factor_type and phone number" do
      setup_session(client, mock_session)

      stub = stub_request(:post, "#{base_url}/factors")
        .with(
          body: hash_including("factor_type" => "phone", "phone" => "+15551234567"),
          headers: { "Authorization" => "Bearer mock-access-token" }
        )
        .to_return(
          status: 200,
          body: {
            "id" => "factor-2", "type" => "phone", "friendly_name" => "my-phone",
            "phone" => "+15551234567"
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      response = client.mfa.enroll(factor_type: "phone", friendly_name: "my-phone", phone: "+15551234567")

      expect(stub).to have_been_requested
      expect(response).to be_a(Supabase::Auth::Types::AuthMFAEnrollResponse)
      expect(response.id).to eq("factor-2")
      expect(response.type).to eq("phone")
      expect(response.phone).to eq("+15551234567")
    end

    it "prepends data:image/svg+xml;utf-8, to QR code for totp factors (matching Python)" do
      setup_session(client, mock_session)

      stub_request(:post, "#{base_url}/factors")
        .to_return(
          status: 200,
          body: {
            "id" => "factor-1", "type" => "totp", "friendly_name" => "test",
            "totp" => { "qr_code" => "<svg>test</svg>", "secret" => "SECRET", "uri" => "otpauth://..." }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      response = client.mfa.enroll(factor_type: "totp", friendly_name: "test")

      expect(response.totp.qr_code).to eq("data:image/svg+xml;utf-8,<svg>test</svg>")
    end

    it "does not modify QR code for phone factors" do
      setup_session(client, mock_session)

      stub_request(:post, "#{base_url}/factors")
        .to_return(
          status: 200,
          body: {
            "id" => "factor-2", "type" => "phone", "friendly_name" => "test",
            "phone" => "+15551234567"
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      response = client.mfa.enroll(factor_type: "phone", friendly_name: "test", phone: "+15551234567")

      expect(response.totp).to be_nil
    end

    it "raises AuthSessionMissing when no session exists (matching Python)" do
      expect {
        client.mfa.enroll(factor_type: "totp", friendly_name: "test")
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end

    it "accepts string keys (matching Python's dict-style params)" do
      setup_session(client, mock_session)

      stub_request(:post, "#{base_url}/factors")
        .to_return(
          status: 200,
          body: {
            "id" => "factor-1", "type" => "totp", "friendly_name" => "test",
            "totp" => { "qr_code" => "<svg>qr</svg>", "secret" => "SECRET", "uri" => "otpauth://..." }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      response = client.mfa.enroll("factor_type" => "totp", "friendly_name" => "test")

      expect(response).to be_a(Supabase::Auth::Types::AuthMFAEnrollResponse)
      expect(response.type).to eq("totp")
    end
  end

  # ── AC-2: challenge sends correct body with optional channel param ──

  describe "AC-2: challenge sends correct body with optional channel param" do
    it "sends POST to /factors/{factor_id}/challenge with channel in body" do
      setup_session(client, mock_session)

      stub = stub_request(:post, "#{base_url}/factors/factor-1/challenge")
        .with(
          body: hash_including("channel" => "sms"),
          headers: { "Authorization" => "Bearer mock-access-token" }
        )
        .to_return(
          status: 200,
          body: { "id" => "challenge-1", "type" => "totp", "expires_at" => Time.now.to_i + 300 }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      response = client.mfa.challenge(factor_id: "factor-1", channel: "sms")

      expect(stub).to have_been_requested
      expect(response).to be_a(Supabase::Auth::Types::AuthMFAChallengeResponse)
      expect(response.id).to eq("challenge-1")
    end

    it "sends POST with nil channel when not provided (matching Python)" do
      setup_session(client, mock_session)

      stub = stub_request(:post, "#{base_url}/factors/factor-1/challenge")
        .to_return(
          status: 200,
          body: { "id" => "challenge-1", "type" => "totp", "expires_at" => Time.now.to_i + 300 }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      response = client.mfa.challenge(factor_id: "factor-1")

      expect(stub).to have_been_requested
      expect(response.id).to eq("challenge-1")
    end

    it "raises AuthSessionMissing when no session exists" do
      expect {
        client.mfa.challenge(factor_id: "factor-1")
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end

    it "returns AuthMFAChallengeResponse with factor_type from 'type' field" do
      setup_session(client, mock_session)

      stub_request(:post, "#{base_url}/factors/factor-1/challenge")
        .to_return(
          status: 200,
          body: { "id" => "challenge-1", "type" => "phone", "expires_at" => Time.now.to_i + 300 }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      response = client.mfa.challenge(factor_id: "factor-1")

      # Python uses validation_alias="type" for factor_type field; Ruby handles both "type" and "factor_type"
      expect(response.factor_type).to eq("phone")
    end
  end

  # ── AC-3: verify sends factor_id, challenge_id, code ──

  describe "AC-3: verify sends factor_id, challenge_id, code" do
    let(:verify_response_body) do
      {
        "access_token" => "mfa-access-token",
        "refresh_token" => "mfa-refresh-token",
        "token_type" => "bearer",
        "expires_in" => 3600,
        "expires_at" => Time.now.to_i + 3600,
        "user" => {
          "id" => "test-user-id",
          "app_metadata" => {},
          "user_metadata" => {},
          "aud" => "test-aud",
          "email" => "test@example.com",
          "created_at" => "2023-01-01T00:00:00Z",
          "updated_at" => "2023-01-01T00:00:00Z"
        }
      }
    end

    it "sends POST to /factors/{factor_id}/verify with factor_id, challenge_id, code in body" do
      setup_session(client, mock_session)

      # FINDING: Python passes full params dict as body (body=params),
      # Ruby constructs { factor_id:, challenge_id:, code: } — functionally equivalent
      # since MFAVerifyParams has exactly those 3 fields
      stub = stub_request(:post, "#{base_url}/factors/factor-1/verify")
        .with(
          body: hash_including(
            "factor_id" => "factor-1",
            "challenge_id" => "challenge-1",
            "code" => "123456"
          ),
          headers: { "Authorization" => "Bearer mock-access-token" }
        )
        .to_return(
          status: 200,
          body: verify_response_body.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      response = client.mfa.verify(factor_id: "factor-1", challenge_id: "challenge-1", code: "123456")

      expect(stub).to have_been_requested
      expect(response).to be_a(Supabase::Auth::Types::AuthMFAVerifyResponse)
      expect(response.access_token).to eq("mfa-access-token")
      expect(response.token_type).to eq("bearer")
      expect(response.refresh_token).to eq("mfa-refresh-token")
      expect(response.user).to be_a(Supabase::Auth::Types::User)
    end

    it "saves the new session after verify (matching Python's _save_session)" do
      setup_session(client, mock_session)

      stub_request(:post, "#{base_url}/factors/factor-1/verify")
        .to_return(
          status: 200,
          body: verify_response_body.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      client.mfa.verify(factor_id: "factor-1", challenge_id: "challenge-1", code: "123456")

      # Session should be updated with the new access token
      new_session = client.instance_variable_get(:@current_session)
      expect(new_session.access_token).to eq("mfa-access-token")
    end

    it "emits MFA_CHALLENGE_VERIFIED event (matching Python)" do
      setup_session(client, mock_session)

      stub_request(:post, "#{base_url}/factors/factor-1/verify")
        .to_return(
          status: 200,
          body: verify_response_body.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      events_received = []
      client.on_auth_state_change do |event, session|
        events_received << event
      end

      client.mfa.verify(factor_id: "factor-1", challenge_id: "challenge-1", code: "123456")

      expect(events_received).to include("MFA_CHALLENGE_VERIFIED")
    end

    it "raises AuthSessionMissing when no session exists" do
      expect {
        client.mfa.verify(factor_id: "factor-1", challenge_id: "challenge-1", code: "123456")
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end
  end

  # ── AC-4: challenge_and_verify chains challenge + verify correctly ──

  describe "AC-4: challenge_and_verify chains challenge + verify" do
    it "calls challenge then verify, returning AuthMFAVerifyResponse" do
      setup_session(client, mock_session)

      # Challenge request
      stub_request(:post, "#{base_url}/factors/factor-1/challenge")
        .to_return(
          status: 200,
          body: { "id" => "challenge-1", "type" => "totp", "expires_at" => Time.now.to_i + 300 }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      # Verify request
      stub_request(:post, "#{base_url}/factors/factor-1/verify")
        .with(body: hash_including("challenge_id" => "challenge-1", "code" => "123456"))
        .to_return(
          status: 200,
          body: {
            "access_token" => "mfa-access-token",
            "refresh_token" => "mfa-refresh-token",
            "token_type" => "bearer",
            "expires_in" => 3600,
            "expires_at" => Time.now.to_i + 3600,
            "user" => {
              "id" => "test-user-id", "app_metadata" => {}, "user_metadata" => {},
              "aud" => "test-aud", "email" => "test@example.com",
              "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z"
            }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      response = client.mfa.challenge_and_verify(factor_id: "factor-1", code: "123456")

      expect(response).to be_a(Supabase::Auth::Types::AuthMFAVerifyResponse)
      expect(response.access_token).to eq("mfa-access-token")
    end

    it "passes challenge_id from challenge response to verify (matching Python)" do
      setup_session(client, mock_session)

      stub_request(:post, "#{base_url}/factors/factor-1/challenge")
        .to_return(
          status: 200,
          body: { "id" => "specific-challenge-id", "type" => "totp", "expires_at" => Time.now.to_i + 300 }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      verify_stub = stub_request(:post, "#{base_url}/factors/factor-1/verify")
        .with(body: hash_including("challenge_id" => "specific-challenge-id"))
        .to_return(
          status: 200,
          body: {
            "access_token" => "token", "refresh_token" => "refresh", "token_type" => "bearer",
            "expires_in" => 3600, "expires_at" => Time.now.to_i + 3600,
            "user" => { "id" => "test-user-id", "app_metadata" => {}, "user_metadata" => {},
                        "aud" => "test-aud", "created_at" => "2023-01-01T00:00:00Z",
                        "updated_at" => "2023-01-01T00:00:00Z" }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      client.mfa.challenge_and_verify(factor_id: "factor-1", code: "123456")

      expect(verify_stub).to have_been_requested
    end
  end

  # ── AC-5: unenroll sends DELETE to /factors/{factor_id} ──

  describe "AC-5: unenroll sends DELETE to /factors/{factor_id}" do
    it "sends DELETE to /factors/{factor_id} with session token" do
      setup_session(client, mock_session)

      stub = stub_request(:delete, "#{base_url}/factors/factor-1")
        .with(headers: { "Authorization" => "Bearer mock-access-token" })
        .to_return(
          status: 200,
          body: { "id" => "factor-1" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      response = client.mfa.unenroll(factor_id: "factor-1")

      expect(stub).to have_been_requested
      expect(response).to be_a(Supabase::Auth::Types::AuthMFAUnenrollResponse)
      expect(response.id).to eq("factor-1")
    end

    it "raises AuthSessionMissing when no session exists" do
      expect {
        client.mfa.unenroll(factor_id: "factor-1")
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end
  end

  # ── AC-6: list_factors categorizes factors into all/totp/phone ──

  describe "AC-6: list_factors categorizes factors into all/totp/phone" do
    it "calls get_user and categorizes factors by type and verified status" do
      totp_verified = Supabase::Auth::Types::Factor.new(
        id: "f1", factor_type: "totp", status: "verified", friendly_name: "totp1",
        created_at: Time.parse("2023-01-01T00:00:00Z"), updated_at: Time.parse("2023-01-01T00:00:00Z")
      )
      phone_verified = Supabase::Auth::Types::Factor.new(
        id: "f2", factor_type: "phone", status: "verified", friendly_name: "phone1",
        created_at: Time.parse("2023-01-01T00:00:00Z"), updated_at: Time.parse("2023-01-01T00:00:00Z")
      )
      totp_unverified = Supabase::Auth::Types::Factor.new(
        id: "f3", factor_type: "totp", status: "unverified", friendly_name: "totp2",
        created_at: Time.parse("2023-01-01T00:00:00Z"), updated_at: Time.parse("2023-01-01T00:00:00Z")
      )

      user_with_factors = Supabase::Auth::Types::User.new(
        id: "test-user-id", app_metadata: {}, user_metadata: {}, aud: "test-aud",
        email: "test@example.com", phone: "",
        created_at: Time.parse("2023-01-01T00:00:00Z"),
        confirmed_at: Time.parse("2023-01-01T00:00:00Z"),
        last_sign_in_at: Time.parse("2023-01-01T00:00:00Z"),
        role: "authenticated",
        updated_at: Time.parse("2023-01-01T00:00:00Z"),
        factors: [totp_verified, phone_verified, totp_unverified]
      )
      user_response = Supabase::Auth::Types::UserResponse.new(user: user_with_factors)

      # Python calls self.get_user() without JWT, Ruby calls @client.get_user — both identical behavior
      allow(client).to receive(:get_user).and_return(user_response)

      response = client.mfa.list_factors

      expect(response).to be_a(Supabase::Auth::Types::AuthMFAListFactorsResponse)
      # all: includes ALL factors (verified and unverified) — matching Python
      expect(response.all.size).to eq(3)
      # totp: only verified TOTP factors — matching Python
      expect(response.totp.size).to eq(1)
      expect(response.totp.first.id).to eq("f1")
      # phone: only verified phone factors — matching Python
      expect(response.phone.size).to eq(1)
      expect(response.phone.first.id).to eq("f2")
    end

    it "returns empty arrays when user has no factors" do
      user_response = Supabase::Auth::Types::UserResponse.new(user: mock_user)
      allow(client).to receive(:get_user).and_return(user_response)

      response = client.mfa.list_factors

      expect(response.all).to eq([])
      expect(response.totp).to eq([])
      expect(response.phone).to eq([])
    end

    it "handles nil factors gracefully (matching Python's `or []`)" do
      user_no_factors = Supabase::Auth::Types::User.new(
        id: "test-user-id", app_metadata: {}, user_metadata: {}, aud: "test-aud",
        email: "test@example.com", phone: "",
        created_at: Time.parse("2023-01-01T00:00:00Z"),
        confirmed_at: Time.parse("2023-01-01T00:00:00Z"),
        last_sign_in_at: Time.parse("2023-01-01T00:00:00Z"),
        role: "authenticated",
        updated_at: Time.parse("2023-01-01T00:00:00Z"),
        factors: nil
      )
      user_response = Supabase::Auth::Types::UserResponse.new(user: user_no_factors)
      allow(client).to receive(:get_user).and_return(user_response)

      response = client.mfa.list_factors

      expect(response.all).to eq([])
      expect(response.totp).to eq([])
      expect(response.phone).to eq([])
    end
  end

  # ── AC-7: get_authenticator_assurance_level correctly parses AMR entries ──

  describe "AC-7: get_authenticator_assurance_level parses AMR and determines AAL" do
    def make_jwt(payload)
      JWT.encode(payload, "test-secret", "HS256")
    end

    it "returns nil levels and empty methods when no session exists" do
      response = client.mfa.get_authenticator_assurance_level

      expect(response).to be_a(Supabase::Auth::Types::AuthMFAGetAuthenticatorAssuranceLevelResponse)
      expect(response.current_level).to be_nil
      expect(response.next_level).to be_nil
      expect(response.current_authentication_methods).to eq([])
    end

    it "returns aal1 with no verified factors — next_level equals current (matching Python)" do
      jwt_token = make_jwt({ "aal" => "aal1", "amr" => [{ "method" => "password", "timestamp" => 1234567890 }], "exp" => Time.now.to_i + 3600 })

      session = Supabase::Auth::Types::Session.new(
        access_token: jwt_token,
        refresh_token: "refresh",
        expires_in: 3600,
        expires_at: Time.now.to_i + 3600,
        token_type: "bearer",
        user: mock_user # has factors: []
      )
      setup_session(client, session)

      response = client.mfa.get_authenticator_assurance_level

      expect(response.current_level).to eq("aal1")
      # Python: next_level = "aal2" if verified_factors else current_level
      # No verified factors → next_level = current_level = "aal1"
      expect(response.next_level).to eq("aal1")
      expect(response.current_authentication_methods.size).to eq(1)
    end

    it "returns aal2 as next_level when verified factors exist (matching Python)" do
      jwt_token = make_jwt({ "aal" => "aal1", "amr" => [{ "method" => "password", "timestamp" => 1234567890 }], "exp" => Time.now.to_i + 3600 })

      user_with_verified_factor = Supabase::Auth::Types::User.new(
        id: "test-user-id", app_metadata: {}, user_metadata: {}, aud: "test-aud",
        email: "test@example.com", phone: "",
        created_at: Time.parse("2023-01-01T00:00:00Z"),
        confirmed_at: Time.parse("2023-01-01T00:00:00Z"),
        last_sign_in_at: Time.parse("2023-01-01T00:00:00Z"),
        role: "authenticated",
        updated_at: Time.parse("2023-01-01T00:00:00Z"),
        factors: [
          Supabase::Auth::Types::Factor.new(
            id: "f1", factor_type: "totp", status: "verified",
            created_at: Time.parse("2023-01-01T00:00:00Z"),
            updated_at: Time.parse("2023-01-01T00:00:00Z")
          )
        ]
      )

      session = Supabase::Auth::Types::Session.new(
        access_token: jwt_token,
        refresh_token: "refresh",
        expires_in: 3600,
        expires_at: Time.now.to_i + 3600,
        token_type: "bearer",
        user: user_with_verified_factor
      )
      setup_session(client, session)

      response = client.mfa.get_authenticator_assurance_level

      expect(response.current_level).to eq("aal1")
      expect(response.next_level).to eq("aal2")
    end

    it "parses AMR entries from JWT payload (matching Python's payload.get('amr'))" do
      amr_entries = [
        { "method" => "password", "timestamp" => 1234567890 },
        { "method" => "totp", "timestamp" => 1234567900 }
      ]
      jwt_token = make_jwt({ "aal" => "aal2", "amr" => amr_entries, "exp" => Time.now.to_i + 3600 })

      session = Supabase::Auth::Types::Session.new(
        access_token: jwt_token,
        refresh_token: "refresh",
        expires_in: 3600,
        expires_at: Time.now.to_i + 3600,
        token_type: "bearer",
        user: mock_user
      )
      setup_session(client, session)

      response = client.mfa.get_authenticator_assurance_level

      expect(response.current_authentication_methods.size).to eq(2)
      expect(response.current_authentication_methods).to eq(amr_entries)
    end

    it "handles missing amr in JWT payload (defaults to empty array, matching Python)" do
      jwt_token = make_jwt({ "aal" => "aal1", "exp" => Time.now.to_i + 3600 })

      session = Supabase::Auth::Types::Session.new(
        access_token: jwt_token,
        refresh_token: "refresh",
        expires_in: 3600,
        expires_at: Time.now.to_i + 3600,
        token_type: "bearer",
        user: mock_user
      )
      setup_session(client, session)

      response = client.mfa.get_authenticator_assurance_level

      # Python: payload.get("amr") or [] — defaults to empty array
      expect(response.current_authentication_methods).to eq([])
    end
  end

  # ── Cross-cutting: verify correct response type structures ──

  describe "Response type parity with Python" do
    it "AuthMFAEnrollResponse has id, type, friendly_name, totp, phone fields" do
      response = Supabase::Auth::Types::AuthMFAEnrollResponse.new(
        id: "f1", type: "totp", friendly_name: "my-factor",
        totp: Supabase::Auth::Types::AuthMFAEnrollResponseTotp.new(
          qr_code: "qr", secret: "sec", uri: "uri"
        ),
        phone: nil
      )
      expect(response.id).to eq("f1")
      expect(response.type).to eq("totp")
      expect(response.friendly_name).to eq("my-factor")
      expect(response.totp.qr_code).to eq("qr")
      expect(response.totp.secret).to eq("sec")
      expect(response.totp.uri).to eq("uri")
      expect(response.phone).to be_nil
    end

    it "AuthMFAChallengeResponse has id, factor_type, expires_at fields" do
      response = Supabase::Auth::Types::AuthMFAChallengeResponse.new(
        id: "c1", factor_type: "totp", expires_at: 1234567890
      )
      expect(response.id).to eq("c1")
      expect(response.factor_type).to eq("totp")
      expect(response.expires_at).to eq(1234567890)
    end

    it "AuthMFAVerifyResponse has access_token, token_type, expires_in, refresh_token, user fields" do
      response = Supabase::Auth::Types::AuthMFAVerifyResponse.new(
        access_token: "token", token_type: "bearer", expires_in: 3600,
        refresh_token: "refresh", user: mock_user
      )
      expect(response.access_token).to eq("token")
      expect(response.token_type).to eq("bearer")
      expect(response.expires_in).to eq(3600)
      expect(response.refresh_token).to eq("refresh")
      expect(response.user).to eq(mock_user)
    end

    it "AuthMFAUnenrollResponse has id field" do
      response = Supabase::Auth::Types::AuthMFAUnenrollResponse.new(id: "f1")
      expect(response.id).to eq("f1")
    end

    it "AuthMFAListFactorsResponse has all, totp, phone fields" do
      response = Supabase::Auth::Types::AuthMFAListFactorsResponse.new(
        all: [], totp: [], phone: []
      )
      expect(response.all).to eq([])
      expect(response.totp).to eq([])
      expect(response.phone).to eq([])
    end

    it "AuthMFAGetAuthenticatorAssuranceLevelResponse has current_level, next_level, current_authentication_methods" do
      response = Supabase::Auth::Types::AuthMFAGetAuthenticatorAssuranceLevelResponse.new(
        current_level: "aal1", next_level: "aal2",
        current_authentication_methods: [{ "method" => "password" }]
      )
      expect(response.current_level).to eq("aal1")
      expect(response.next_level).to eq("aal2")
      expect(response.current_authentication_methods).to eq([{ "method" => "password" }])
    end
  end
end
