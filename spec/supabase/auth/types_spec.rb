# frozen_string_literal: true

RSpec.describe Supabase::Auth::Types do
  describe ".parse_timestamp" do
    it "returns nil for nil input" do
      expect(described_class.parse_timestamp(nil)).to be_nil
    end

    it "returns Time object unchanged" do
      time = Time.now
      expect(described_class.parse_timestamp(time)).to eq(time)
    end

    it "parses ISO8601 string into Time" do
      result = described_class.parse_timestamp("2024-01-15T10:30:00Z")
      expect(result).to be_a(Time)
      expect(result.year).to eq(2024)
      expect(result.month).to eq(1)
      expect(result.day).to eq(15)
    end
  end

  describe Supabase::Auth::Types::Factor do
    it "creates with keyword arguments" do
      factor = described_class.new(
        id: "factor-1",
        friendly_name: "My TOTP",
        factor_type: "totp",
        status: "verified",
        created_at: Time.now,
        updated_at: Time.now
      )
      expect(factor.id).to eq("factor-1")
      expect(factor.friendly_name).to eq("My TOTP")
      expect(factor.factor_type).to eq("totp")
      expect(factor.status).to eq("verified")
    end

    it "creates from hash with string keys and parses timestamps" do
      factor = described_class.from_hash(
        "id" => "factor-1",
        "friendly_name" => "My TOTP",
        "factor_type" => "totp",
        "status" => "verified",
        "created_at" => "2024-01-15T10:30:00Z",
        "updated_at" => "2024-01-15T11:00:00Z"
      )
      expect(factor.id).to eq("factor-1")
      expect(factor.created_at).to be_a(Time)
      expect(factor.updated_at).to be_a(Time)
    end

    it "returns nil from_hash when given nil" do
      expect(described_class.from_hash(nil)).to be_nil
    end
  end

  describe Supabase::Auth::Types::Identity do
    it "creates with keyword arguments" do
      identity = described_class.new(
        id: "identity-1",
        user_id: "user-1",
        identity_data: { "email" => "test@example.com" },
        provider: "email",
        created_at: Time.now,
        updated_at: Time.now
      )
      expect(identity.id).to eq("identity-1")
      expect(identity.provider).to eq("email")
      expect(identity.identity_data).to eq({ "email" => "test@example.com" })
    end

    it "creates from hash with timestamp parsing" do
      identity = described_class.from_hash(
        "id" => "identity-1",
        "user_id" => "user-1",
        "identity_data" => { "email" => "test@example.com" },
        "provider" => "email",
        "last_sign_in_at" => "2024-01-15T10:30:00Z",
        "created_at" => "2024-01-01T00:00:00Z",
        "updated_at" => "2024-01-15T10:30:00Z"
      )
      expect(identity.last_sign_in_at).to be_a(Time)
      expect(identity.created_at).to be_a(Time)
    end

    it "returns nil from_hash when given nil" do
      expect(described_class.from_hash(nil)).to be_nil
    end
  end

  describe Supabase::Auth::Types::User do
    let(:user_hash) do
      {
        "id" => "user-123",
        "aud" => "authenticated",
        "role" => "authenticated",
        "email" => "test@example.com",
        "email_confirmed_at" => "2024-01-15T10:30:00Z",
        "phone" => "+1234567890",
        "phone_confirmed_at" => "2024-01-15T10:30:00Z",
        "confirmed_at" => "2024-01-15T10:30:00Z",
        "last_sign_in_at" => "2024-01-16T08:00:00Z",
        "app_metadata" => { "provider" => "email" },
        "user_metadata" => { "name" => "Test User" },
        "identities" => [
          {
            "id" => "identity-1",
            "user_id" => "user-123",
            "identity_data" => {},
            "provider" => "email",
            "created_at" => "2024-01-15T10:30:00Z",
            "updated_at" => "2024-01-15T10:30:00Z"
          }
        ],
        "factors" => [
          {
            "id" => "factor-1",
            "friendly_name" => "My TOTP",
            "factor_type" => "totp",
            "status" => "verified",
            "created_at" => "2024-01-15T10:30:00Z",
            "updated_at" => "2024-01-15T10:30:00Z"
          }
        ],
        "created_at" => "2024-01-01T00:00:00Z",
        "updated_at" => "2024-01-16T08:00:00Z"
      }
    end

    it "creates with keyword arguments" do
      user = described_class.new(id: "user-123", email: "test@example.com")
      expect(user.id).to eq("user-123")
      expect(user.email).to eq("test@example.com")
    end

    it "creates from hash with nested objects and timestamp parsing" do
      user = described_class.from_hash(user_hash)

      expect(user.id).to eq("user-123")
      expect(user.aud).to eq("authenticated")
      expect(user.role).to eq("authenticated")
      expect(user.email).to eq("test@example.com")
      expect(user.email_confirmed_at).to be_a(Time)
      expect(user.phone).to eq("+1234567890")
      expect(user.phone_confirmed_at).to be_a(Time)
      expect(user.confirmed_at).to be_a(Time)
      expect(user.last_sign_in_at).to be_a(Time)
      expect(user.app_metadata).to eq({ "provider" => "email" })
      expect(user.user_metadata).to eq({ "name" => "Test User" })
      expect(user.created_at).to be_a(Time)
      expect(user.updated_at).to be_a(Time)
    end

    it "parses nested identities" do
      user = described_class.from_hash(user_hash)
      expect(user.identities).to be_an(Array)
      expect(user.identities.length).to eq(1)
      expect(user.identities.first).to be_a(Supabase::Auth::Types::Identity)
      expect(user.identities.first.provider).to eq("email")
    end

    it "parses nested factors" do
      user = described_class.from_hash(user_hash)
      expect(user.factors).to be_an(Array)
      expect(user.factors.length).to eq(1)
      expect(user.factors.first).to be_a(Supabase::Auth::Types::Factor)
      expect(user.factors.first.factor_type).to eq("totp")
    end

    it "handles nil identities and factors" do
      user = described_class.from_hash("id" => "user-1", "created_at" => "2024-01-01T00:00:00Z")
      expect(user.identities).to be_nil
      expect(user.factors).to be_nil
    end

    it "returns nil from_hash when given nil" do
      expect(described_class.from_hash(nil)).to be_nil
    end
  end

  describe Supabase::Auth::Types::Session do
    it "creates with keyword arguments" do
      session = described_class.new(
        access_token: "token-abc",
        refresh_token: "refresh-xyz",
        token_type: "bearer",
        expires_in: 3600,
        expires_at: Time.at(1_705_312_200),
        user: Supabase::Auth::Types::User.new(id: "user-1")
      )
      expect(session.access_token).to eq("token-abc")
      expect(session.refresh_token).to eq("refresh-xyz")
      expect(session.expires_at).to be_a(Time)
    end

    it "creates from hash with nested user and expires_at as epoch" do
      session = described_class.from_hash(
        "access_token" => "token-abc",
        "refresh_token" => "refresh-xyz",
        "token_type" => "bearer",
        "expires_in" => 3600,
        "expires_at" => 1_705_312_200,
        "user" => { "id" => "user-1", "created_at" => "2024-01-01T00:00:00Z" }
      )

      expect(session.access_token).to eq("token-abc")
      expect(session.expires_in).to eq(3600)
      expect(session.expires_at).to be_a(Integer)
      expect(session.expires_at).to eq(1_705_312_200)
      expect(session.user).to be_a(Supabase::Auth::Types::User)
      expect(session.user.id).to eq("user-1")
    end

    it "computes expires_at from expires_in when expires_at is nil" do
      now = Time.now.to_i
      session = described_class.from_hash(
        "access_token" => "token",
        "refresh_token" => "refresh",
        "token_type" => "bearer",
        "expires_in" => 3600,
        "user" => { "id" => "user-1" }
      )
      expect(session.expires_at).to be_a(Integer)
      expect(session.expires_at).to be_within(2).of(now + 3600)
    end

    it "returns nil expires_at when both expires_at and expires_in are nil" do
      session = described_class.from_hash(
        "access_token" => "token",
        "refresh_token" => "refresh",
        "token_type" => "bearer",
        "user" => { "id" => "user-1" }
      )
      expect(session.expires_at).to be_nil
    end

    it "returns nil from_hash when given nil" do
      expect(described_class.from_hash(nil)).to be_nil
    end
  end

  describe Supabase::Auth::Types::AuthResponse do
    it "creates with keyword arguments" do
      response = described_class.new(
        user: Supabase::Auth::Types::User.new(id: "user-1"),
        session: nil
      )
      expect(response.user.id).to eq("user-1")
      expect(response.session).to be_nil
    end

    it "creates from hash with nested user and session" do
      response = described_class.from_hash(
        "user" => { "id" => "user-1", "email" => "test@example.com" },
        "session" => {
          "access_token" => "token",
          "refresh_token" => "refresh",
          "token_type" => "bearer",
          "expires_in" => 3600,
          "user" => { "id" => "user-1" }
        }
      )

      expect(response.user).to be_a(Supabase::Auth::Types::User)
      expect(response.session).to be_a(Supabase::Auth::Types::Session)
      expect(response.session.access_token).to eq("token")
    end

    it "returns nil from_hash when given nil" do
      expect(described_class.from_hash(nil)).to be_nil
    end
  end

  describe Supabase::Auth::Types::OAuthResponse do
    it "creates with keyword arguments" do
      response = described_class.new(provider: "google", url: "https://accounts.google.com/...")
      expect(response.provider).to eq("google")
      expect(response.url).to eq("https://accounts.google.com/...")
    end
  end

  # ===== US-006 Type Audit Tests =====
  # Verify all type definitions match Python Pydantic models

  describe "User struct field parity with Python" do
    it "has all fields from Python User model" do
      expected_fields = %i[
        id aud role email email_confirmed_at phone phone_confirmed_at
        confirmed_at last_sign_in_at app_metadata user_metadata identities
        factors created_at updated_at new_email new_phone invited_at
        is_anonymous confirmation_sent_at recovery_sent_at email_change_sent_at
        action_link
      ]
      user = Supabase::Auth::Types::User.new
      expected_fields.each do |field|
        expect(user).to respond_to(field), "Missing field: #{field}"
      end
    end

    it "defaults is_anonymous to false matching Python" do
      user = Supabase::Auth::Types::User.from_hash("id" => "u1")
      expect(user.is_anonymous).to eq(false)
    end

    it "handles is_anonymous=true from hash" do
      user = Supabase::Auth::Types::User.from_hash("id" => "u1", "is_anonymous" => true)
      expect(user.is_anonymous).to eq(true)
    end

    it "defaults app_metadata and user_metadata to empty hash" do
      user = Supabase::Auth::Types::User.from_hash("id" => "u1")
      expect(user.app_metadata).to eq({})
      expect(user.user_metadata).to eq({})
    end

    it "handles symbol keys in from_hash" do
      user = Supabase::Auth::Types::User.from_hash(id: "u1", email: "a@b.com", aud: "auth")
      expect(user.id).to eq("u1")
      expect(user.email).to eq("a@b.com")
    end
  end

  describe "Session struct field parity with Python" do
    it "has all fields from Python Session model" do
      expected_fields = %i[
        provider_token provider_refresh_token access_token refresh_token
        token_type expires_in expires_at user
      ]
      session = Supabase::Auth::Types::Session.new
      expected_fields.each do |field|
        expect(session).to respond_to(field), "Missing field: #{field}"
      end
    end

    it "computes expires_at = round(time()) + expires_in when expires_at missing (matching Python validator)" do
      before = Time.now.round.to_i
      session = Supabase::Auth::Types::Session.from_hash(
        "access_token" => "t", "refresh_token" => "r", "token_type" => "bearer",
        "expires_in" => 3600, "user" => { "id" => "u1" }
      )
      after = Time.now.round.to_i
      expect(session.expires_at).to be_between(before + 3600, after + 3600)
      expect(session.expires_at).to be_a(Integer)
    end

    it "preserves existing expires_at as integer" do
      session = Supabase::Auth::Types::Session.from_hash(
        "access_token" => "t", "refresh_token" => "r", "token_type" => "bearer",
        "expires_in" => 3600, "expires_at" => 1700000000, "user" => { "id" => "u1" }
      )
      expect(session.expires_at).to eq(1700000000)
    end

    it "parses nested User from hash" do
      session = Supabase::Auth::Types::Session.from_hash(
        "access_token" => "t", "refresh_token" => "r", "token_type" => "bearer",
        "expires_in" => 3600, "user" => { "id" => "u1", "email" => "a@b.com" }
      )
      expect(session.user).to be_a(Supabase::Auth::Types::User)
      expect(session.user.email).to eq("a@b.com")
    end
  end

  describe "Factor struct field parity with Python" do
    it "has all fields: id, friendly_name, factor_type, status, created_at, updated_at" do
      factor = Supabase::Auth::Types::Factor.new(
        id: "f1", friendly_name: nil, factor_type: "totp",
        status: "verified", created_at: Time.now, updated_at: Time.now
      )
      expect(factor.id).to eq("f1")
      expect(factor.friendly_name).to be_nil
      expect(factor.factor_type).to eq("totp")
      expect(factor.status).to eq("verified")
    end

    it "parses timestamps via from_hash" do
      factor = Supabase::Auth::Types::Factor.from_hash(
        "id" => "f1", "factor_type" => "phone", "status" => "unverified",
        "created_at" => "2024-06-01T00:00:00Z", "updated_at" => "2024-06-01T00:00:00Z"
      )
      expect(factor.created_at).to be_a(Time)
      expect(factor.updated_at).to be_a(Time)
    end
  end

  describe "Identity struct field parity with Python UserIdentity" do
    it "has all fields: id, identity_id, user_id, identity_data, provider, created_at, last_sign_in_at, updated_at" do
      identity = Supabase::Auth::Types::Identity.from_hash(
        "id" => "i1", "identity_id" => "ii1", "user_id" => "u1",
        "identity_data" => { "email" => "a@b.com" }, "provider" => "google",
        "created_at" => "2024-01-01T00:00:00Z", "last_sign_in_at" => "2024-06-01T00:00:00Z",
        "updated_at" => "2024-06-01T00:00:00Z"
      )
      expect(identity.id).to eq("i1")
      expect(identity.identity_id).to eq("ii1")
      expect(identity.user_id).to eq("u1")
      expect(identity.provider).to eq("google")
      expect(identity.identity_data).to eq({ "email" => "a@b.com" })
      expect(identity.last_sign_in_at).to be_a(Time)
    end

    it "defaults identity_data to empty hash when nil" do
      identity = Supabase::Auth::Types::Identity.from_hash("id" => "i1", "provider" => "email", "created_at" => "2024-01-01T00:00:00Z")
      expect(identity.identity_data).to eq({})
    end
  end

  describe "AMREntry struct (matches Python AMREntry)" do
    it "has method and timestamp fields" do
      entry = Supabase::Auth::Types::AMREntry.new(method: "password", timestamp: 1700000000)
      expect(entry.method).to eq("password")
      expect(entry.timestamp).to eq(1700000000)
    end

    it "creates from hash with string keys" do
      entry = Supabase::Auth::Types::AMREntry.from_hash("method" => "otp", "timestamp" => 1700000000)
      expect(entry.method).to eq("otp")
      expect(entry.timestamp).to eq(1700000000)
    end

    it "creates from hash with symbol keys" do
      entry = Supabase::Auth::Types::AMREntry.from_hash(method: "mfa/totp", timestamp: 1700000000)
      expect(entry.method).to eq("mfa/totp")
    end

    it "returns nil from_hash when given nil" do
      expect(Supabase::Auth::Types::AMREntry.from_hash(nil)).to be_nil
    end
  end

  describe "AuthResponse fields match Python" do
    it "has user and session fields, both optional" do
      response = Supabase::Auth::Types::AuthResponse.from_hash({})
      expect(response.user).to be_nil
      expect(response.session).to be_nil
    end
  end

  describe "AuthOtpResponse matches Python" do
    it "has message_id, user, session fields" do
      response = Supabase::Auth::Types::AuthOtpResponse.from_hash(
        "message_id" => "msg-123"
      )
      expect(response.message_id).to eq("msg-123")
      expect(response.user).to be_nil
      expect(response.session).to be_nil
    end

    it "handles both string and symbol keys" do
      response = Supabase::Auth::Types::AuthOtpResponse.from_hash(message_id: "msg-456")
      expect(response.message_id).to eq("msg-456")
    end
  end

  describe "SSOResponse matches Python" do
    it "has url field" do
      response = Supabase::Auth::Types::SSOResponse.from_hash("url" => "https://sso.example.com")
      expect(response.url).to eq("https://sso.example.com")
    end
  end

  describe "LinkIdentityResponse matches Python" do
    it "has url field" do
      response = Supabase::Auth::Types::LinkIdentityResponse.from_hash("url" => "https://link.example.com")
      expect(response.url).to eq("https://link.example.com")
    end
  end

  describe "UserResponse matches Python" do
    it "wraps User object" do
      response = Supabase::Auth::Types::UserResponse.from_hash(
        "user" => { "id" => "u1", "email" => "a@b.com" }
      )
      expect(response.user).to be_a(Supabase::Auth::Types::User)
      expect(response.user.id).to eq("u1")
    end
  end

  describe "GenerateLinkProperties matches Python" do
    it "has action_link, email_otp, hashed_token, redirect_to, verification_type" do
      props = Supabase::Auth::Types::GenerateLinkProperties.new(
        action_link: "https://auth/v1/verify?token=abc",
        email_otp: "123456",
        hashed_token: "hashed",
        redirect_to: "https://app.com",
        verification_type: "signup"
      )
      expect(props.action_link).to include("verify")
      expect(props.email_otp).to eq("123456")
      expect(props.verification_type).to eq("signup")
    end
  end

  describe "GenerateLinkResponse matches Python" do
    it "has properties and user fields" do
      response = Supabase::Auth::Types::GenerateLinkResponse.new(
        properties: Supabase::Auth::Types::GenerateLinkProperties.new(
          action_link: "link", email_otp: "otp", hashed_token: "hash",
          redirect_to: "url", verification_type: "invite"
        ),
        user: Supabase::Auth::Types::User.new(id: "u1")
      )
      expect(response.properties).to be_a(Supabase::Auth::Types::GenerateLinkProperties)
      expect(response.user).to be_a(Supabase::Auth::Types::User)
    end
  end

  describe "IdentitiesResponse matches Python" do
    it "has identities list" do
      response = Supabase::Auth::Types::IdentitiesResponse.new(identities: [])
      expect(response.identities).to eq([])
    end
  end

  describe "AuthMFAEnrollResponse matches Python" do
    it "has id, type, friendly_name, totp, phone fields" do
      response = Supabase::Auth::Types::AuthMFAEnrollResponse.from_hash(
        "id" => "f1", "type" => "totp", "friendly_name" => "My TOTP",
        "totp" => { "qr_code" => "<svg>...</svg>", "secret" => "BASE32SECRET", "uri" => "otpauth://totp/..." }
      )
      expect(response.id).to eq("f1")
      expect(response.type).to eq("totp")
      expect(response.friendly_name).to eq("My TOTP")
      expect(response.totp).to be_a(Supabase::Auth::Types::AuthMFAEnrollResponseTotp)
      expect(response.totp.qr_code).to eq("<svg>...</svg>")
      expect(response.totp.secret).to eq("BASE32SECRET")
      expect(response.totp.uri).to include("otpauth://")
      expect(response.phone).to be_nil
    end

    it "handles phone type enrollment" do
      response = Supabase::Auth::Types::AuthMFAEnrollResponse.from_hash(
        "id" => "f2", "type" => "phone", "friendly_name" => "My Phone",
        "phone" => "+1234567890"
      )
      expect(response.type).to eq("phone")
      expect(response.phone).to eq("+1234567890")
      expect(response.totp).to be_nil
    end
  end

  describe "AuthMFAChallengeResponse matches Python" do
    it "has id, expires_at, factor_type fields" do
      response = Supabase::Auth::Types::AuthMFAChallengeResponse.from_hash(
        "id" => "c1", "expires_at" => 1700000000, "type" => "totp"
      )
      expect(response.id).to eq("c1")
      expect(response.expires_at).to eq(1700000000)
      expect(response.factor_type).to eq("totp")
    end

    it "maps factor_type from 'type' alias matching Python Field(validation_alias='type')" do
      response = Supabase::Auth::Types::AuthMFAChallengeResponse.from_hash(
        "id" => "c1", "expires_at" => 1700000000, "type" => "phone"
      )
      expect(response.factor_type).to eq("phone")
    end

    it "uses factor_type key directly when present" do
      response = Supabase::Auth::Types::AuthMFAChallengeResponse.from_hash(
        "id" => "c1", "expires_at" => 1700000000, "factor_type" => "totp"
      )
      expect(response.factor_type).to eq("totp")
    end
  end

  describe "AuthMFAVerifyResponse matches Python" do
    it "has access_token, token_type, expires_in, refresh_token, user (no expires_at)" do
      response = Supabase::Auth::Types::AuthMFAVerifyResponse.from_hash(
        "access_token" => "at", "token_type" => "bearer", "expires_in" => 3600,
        "refresh_token" => "rt",
        "user" => { "id" => "u1", "app_metadata" => {}, "user_metadata" => {}, "aud" => "auth",
                     "created_at" => "2024-01-01T00:00:00Z", "updated_at" => "2024-01-01T00:00:00Z" }
      )
      expect(response.access_token).to eq("at")
      expect(response.token_type).to eq("bearer")
      expect(response.expires_in).to eq(3600)
      expect(response.refresh_token).to eq("rt")
      expect(response.user).to be_a(Supabase::Auth::Types::User)
    end

    it "does NOT have expires_at field (matching Python AuthMFAVerifyResponse)" do
      expect(Supabase::Auth::Types::AuthMFAVerifyResponse.members).not_to include(:expires_at)
    end

    it "field order matches Python: access_token, token_type, expires_in, refresh_token, user" do
      expect(Supabase::Auth::Types::AuthMFAVerifyResponse.members).to eq(
        [:access_token, :token_type, :expires_in, :refresh_token, :user]
      )
    end
  end

  describe "AuthMFAUnenrollResponse matches Python" do
    it "has id field" do
      response = Supabase::Auth::Types::AuthMFAUnenrollResponse.from_hash("id" => "f1")
      expect(response.id).to eq("f1")
    end
  end

  describe "AuthMFAListFactorsResponse matches Python" do
    it "has all, totp, phone fields" do
      response = Supabase::Auth::Types::AuthMFAListFactorsResponse.new(
        all: [], totp: [], phone: []
      )
      expect(response.all).to eq([])
      expect(response.totp).to eq([])
      expect(response.phone).to eq([])
    end
  end

  describe "AuthMFAGetAuthenticatorAssuranceLevelResponse matches Python" do
    it "has current_level, next_level, current_authentication_methods" do
      response = Supabase::Auth::Types::AuthMFAGetAuthenticatorAssuranceLevelResponse.new(
        current_level: "aal1", next_level: "aal2",
        current_authentication_methods: [
          Supabase::Auth::Types::AMREntry.new(method: "password", timestamp: 1700000000)
        ]
      )
      expect(response.current_level).to eq("aal1")
      expect(response.next_level).to eq("aal2")
      expect(response.current_authentication_methods.first.method).to eq("password")
    end
  end

  describe "AuthMFAAdminListFactorsResponse matches Python" do
    it "wraps factors list via from_hash" do
      response = Supabase::Auth::Types::AuthMFAAdminListFactorsResponse.from_hash(
        "factors" => [
          { "id" => "f1", "factor_type" => "totp", "status" => "verified",
            "created_at" => "2024-01-01T00:00:00Z", "updated_at" => "2024-01-01T00:00:00Z" }
        ]
      )
      expect(response.factors.length).to eq(1)
      expect(response.factors.first).to be_a(Supabase::Auth::Types::Factor)
    end
  end

  describe "AuthMFAAdminDeleteFactorResponse matches Python" do
    it "has id field" do
      response = Supabase::Auth::Types::AuthMFAAdminDeleteFactorResponse.from_hash("id" => "f1")
      expect(response.id).to eq("f1")
    end
  end

  describe "Subscription matches Python" do
    it "has id, callback, unsubscribe fields" do
      sub = Supabase::Auth::Types::Subscription.new(
        id: "sub-1", callback: -> {}, unsubscribe: -> {}
      )
      expect(sub.id).to eq("sub-1")
      expect(sub.callback).to respond_to(:call)
      expect(sub.unsubscribe).to respond_to(:call)
    end
  end

  describe "Timestamp parsing handles ISO8601 correctly" do
    it "parses standard ISO8601 with timezone" do
      time = Supabase::Auth::Types.parse_timestamp("2024-06-15T14:30:00+05:00")
      expect(time).to be_a(Time)
      expect(time.utc.hour).to eq(9)
      expect(time.utc.min).to eq(30)
    end

    it "parses ISO8601 with Z suffix" do
      time = Supabase::Auth::Types.parse_timestamp("2024-01-01T00:00:00Z")
      expect(time).to be_a(Time)
      expect(time.utc.year).to eq(2024)
    end

    it "parses ISO8601 with milliseconds" do
      time = Supabase::Auth::Types.parse_timestamp("2024-06-15T14:30:00.123Z")
      expect(time).to be_a(Time)
    end

    it "converts string values via to_s" do
      time = Supabase::Auth::Types.parse_timestamp("2024-01-01T00:00:00Z")
      expect(time).to be_a(Time)
    end
  end

  describe "from_hash handles both string and symbol keys" do
    it "Factor.from_hash with symbol keys" do
      factor = Supabase::Auth::Types::Factor.from_hash(
        id: "f1", factor_type: "totp", status: "verified",
        created_at: "2024-01-01T00:00:00Z", updated_at: "2024-01-01T00:00:00Z"
      )
      expect(factor.id).to eq("f1")
    end

    it "Session.from_hash with symbol keys" do
      session = Supabase::Auth::Types::Session.from_hash(
        access_token: "t", refresh_token: "r", token_type: "bearer",
        expires_in: 3600, user: { id: "u1" }
      )
      expect(session.access_token).to eq("t")
    end

    it "AuthMFAEnrollResponse.from_hash with symbol keys" do
      response = Supabase::Auth::Types::AuthMFAEnrollResponse.from_hash(
        id: "f1", type: "totp", friendly_name: "My Auth",
        totp: { qr_code: "qr", secret: "s", uri: "u" }
      )
      expect(response.id).to eq("f1")
      expect(response.totp.qr_code).to eq("qr")
    end

    it "AuthMFAChallengeResponse.from_hash with symbol keys" do
      response = Supabase::Auth::Types::AuthMFAChallengeResponse.from_hash(
        id: "c1", expires_at: 1700000000, type: "totp"
      )
      expect(response.factor_type).to eq("totp")
    end

    it "AuthMFAVerifyResponse.from_hash with symbol keys" do
      response = Supabase::Auth::Types::AuthMFAVerifyResponse.from_hash(
        access_token: "at", token_type: "bearer", expires_in: 3600,
        refresh_token: "rt", user: { id: "u1" }
      )
      expect(response.access_token).to eq("at")
    end
  end

  describe "MFATotpInfo alias" do
    it "MFATotpInfo is the same as AuthMFAEnrollResponseTotp" do
      expect(Supabase::Auth::Types::MFATotpInfo).to eq(Supabase::Auth::Types::AuthMFAEnrollResponseTotp)
    end
  end
end
