# frozen_string_literal: true

require "spec_helper"
require "time"

# US-006: Audit Type Definitions
# Verifies all type/model definitions match Python's Pydantic models.
RSpec.describe "US-006: Type Definitions Audit" do
  let(:now_iso) { "2024-01-15T10:30:00Z" }
  let(:now_time) { Time.parse(now_iso) }
  let(:unix_ts) { Time.now.to_i }

  # ─── AC-1: User struct has all fields matching Python's User model ───
  describe "AC-1: User struct field parity with Python" do
    let(:python_user_fields) do
      %i[
        id aud role email phone
        email_confirmed_at phone_confirmed_at confirmed_at last_sign_in_at
        app_metadata user_metadata
        identities factors
        created_at updated_at
        new_email new_phone invited_at
        is_anonymous
        confirmation_sent_at recovery_sent_at email_change_sent_at
        action_link
      ]
    end

    it "has all fields matching Python's User model" do
      ruby_fields = Supabase::Auth::Types::User.members
      python_user_fields.each do |field|
        expect(ruby_fields).to include(field), "Missing field: #{field}"
      end
    end

    it "parses a full User hash with all fields" do
      hash = {
        "id" => "user-123",
        "aud" => "authenticated",
        "role" => "authenticated",
        "email" => "test@example.com",
        "phone" => "+1234567890",
        "email_confirmed_at" => now_iso,
        "phone_confirmed_at" => now_iso,
        "confirmed_at" => now_iso,
        "last_sign_in_at" => now_iso,
        "app_metadata" => { "provider" => "email" },
        "user_metadata" => { "name" => "Test" },
        "identities" => [],
        "factors" => [],
        "created_at" => now_iso,
        "updated_at" => now_iso,
        "new_email" => "new@example.com",
        "new_phone" => "+9876543210",
        "invited_at" => now_iso,
        "is_anonymous" => false,
        "confirmation_sent_at" => now_iso,
        "recovery_sent_at" => now_iso,
        "email_change_sent_at" => now_iso,
        "action_link" => "https://example.com/verify"
      }

      user = Supabase::Auth::Types::User.from_hash(hash)
      expect(user.id).to eq("user-123")
      expect(user.aud).to eq("authenticated")
      expect(user.role).to eq("authenticated")
      expect(user.email).to eq("test@example.com")
      expect(user.phone).to eq("+1234567890")
      expect(user.app_metadata).to eq({ "provider" => "email" })
      expect(user.user_metadata).to eq({ "name" => "Test" })
      expect(user.identities).to eq([])
      expect(user.factors).to eq([])
      expect(user.new_email).to eq("new@example.com")
      expect(user.new_phone).to eq("+9876543210")
      expect(user.is_anonymous).to eq(false)
      expect(user.action_link).to eq("https://example.com/verify")
    end

    it "defaults is_anonymous to false (matches Python default)" do
      user = Supabase::Auth::Types::User.from_hash({ "id" => "u1", "aud" => "auth" })
      expect(user.is_anonymous).to eq(false)
    end

    it "handles is_anonymous=true explicitly" do
      user = Supabase::Auth::Types::User.from_hash({ "id" => "u1", "is_anonymous" => true })
      expect(user.is_anonymous).to eq(true)
    end

    it "defaults app_metadata and user_metadata to empty hash (matches Python)" do
      user = Supabase::Auth::Types::User.from_hash({ "id" => "u1" })
      expect(user.app_metadata).to eq({})
      expect(user.user_metadata).to eq({})
    end

    it "recursively parses identities array" do
      hash = {
        "id" => "u1",
        "identities" => [
          { "id" => "i1", "identity_id" => "ii1", "user_id" => "u1", "provider" => "google",
            "identity_data" => {}, "created_at" => now_iso }
        ]
      }
      user = Supabase::Auth::Types::User.from_hash(hash)
      expect(user.identities.length).to eq(1)
      expect(user.identities.first).to be_a(Supabase::Auth::Types::Identity)
      expect(user.identities.first.provider).to eq("google")
    end

    it "recursively parses factors array" do
      hash = {
        "id" => "u1",
        "factors" => [
          { "id" => "f1", "factor_type" => "totp", "status" => "verified",
            "created_at" => now_iso, "updated_at" => now_iso }
        ]
      }
      user = Supabase::Auth::Types::User.from_hash(hash)
      expect(user.factors.length).to eq(1)
      expect(user.factors.first).to be_a(Supabase::Auth::Types::Factor)
      expect(user.factors.first.factor_type).to eq("totp")
    end

    it "parses all timestamp fields as Time objects" do
      timestamp_fields = %w[
        email_confirmed_at phone_confirmed_at confirmed_at last_sign_in_at
        created_at updated_at invited_at confirmation_sent_at
        recovery_sent_at email_change_sent_at
      ]
      hash = { "id" => "u1" }.merge(timestamp_fields.map { |f| [f, now_iso] }.to_h)
      user = Supabase::Auth::Types::User.from_hash(hash)

      timestamp_fields.each do |field|
        value = user.send(field.to_sym)
        expect(value).to be_a(Time), "#{field} should be Time, got #{value.class}"
      end
    end
  end

  # ─── AC-2: Session struct computes expires_at from expires_in ───
  describe "AC-2: Session expires_at computation" do
    it "computes expires_at from expires_in when expires_at is missing (matches Python validator)" do
      before = Time.now.to_i
      session = Supabase::Auth::Types::Session.from_hash({
        "access_token" => "at",
        "refresh_token" => "rt",
        "token_type" => "bearer",
        "expires_in" => 3600,
        "user" => { "id" => "u1" }
      })
      after = Time.now.to_i

      # Python: round(time()) + expires_in
      # Ruby: Time.now.to_i + expires_in.to_i
      expect(session.expires_at).to be_between(before + 3600, after + 3600)
    end

    it "preserves expires_at when provided (does not overwrite)" do
      session = Supabase::Auth::Types::Session.from_hash({
        "access_token" => "at",
        "refresh_token" => "rt",
        "token_type" => "bearer",
        "expires_in" => 3600,
        "expires_at" => 1700000000,
        "user" => { "id" => "u1" }
      })
      expect(session.expires_at).to eq(1700000000)
    end

    it "has all fields matching Python's Session model" do
      python_session_fields = %i[
        provider_token provider_refresh_token
        access_token refresh_token
        expires_in expires_at
        token_type user
      ]
      ruby_fields = Supabase::Auth::Types::Session.members
      python_session_fields.each do |field|
        expect(ruby_fields).to include(field), "Missing Session field: #{field}"
      end
    end

    it "recursively parses nested User object" do
      session = Supabase::Auth::Types::Session.from_hash({
        "access_token" => "at", "refresh_token" => "rt",
        "token_type" => "bearer", "expires_in" => 3600,
        "user" => { "id" => "u1", "email" => "test@test.com" }
      })
      expect(session.user).to be_a(Supabase::Auth::Types::User)
      expect(session.user.email).to eq("test@test.com")
    end

    it "converts expires_at to integer (matches Python int type)" do
      session = Supabase::Auth::Types::Session.from_hash({
        "access_token" => "at", "refresh_token" => "rt",
        "token_type" => "bearer", "expires_in" => 3600,
        "expires_at" => "1700000000",
        "user" => { "id" => "u1" }
      })
      expect(session.expires_at).to be_a(Integer)
    end
  end

  # ─── AC-3: Factor struct matches Python ───
  describe "AC-3: Factor struct" do
    let(:python_factor_fields) { %i[id friendly_name factor_type status created_at updated_at] }

    it "has all fields matching Python's Factor model" do
      ruby_fields = Supabase::Auth::Types::Factor.members
      python_factor_fields.each do |field|
        expect(ruby_fields).to include(field), "Missing Factor field: #{field}"
      end
    end

    it "parses from hash correctly" do
      factor = Supabase::Auth::Types::Factor.from_hash({
        "id" => "f1",
        "friendly_name" => "My TOTP",
        "factor_type" => "totp",
        "status" => "verified",
        "created_at" => now_iso,
        "updated_at" => now_iso
      })
      expect(factor.id).to eq("f1")
      expect(factor.friendly_name).to eq("My TOTP")
      expect(factor.factor_type).to eq("totp")
      expect(factor.status).to eq("verified")
      expect(factor.created_at).to be_a(Time)
      expect(factor.updated_at).to be_a(Time)
    end

    it "supports phone factor type" do
      factor = Supabase::Auth::Types::Factor.from_hash({
        "id" => "f2", "factor_type" => "phone", "status" => "unverified",
        "created_at" => now_iso, "updated_at" => now_iso
      })
      expect(factor.factor_type).to eq("phone")
    end
  end

  # ─── AC-4: Identity / UserIdentity structs match Python ───
  describe "AC-4: Identity and UserIdentity structs" do
    let(:python_identity_fields) do
      %i[id identity_id user_id identity_data provider created_at last_sign_in_at updated_at]
    end

    it "Identity has all fields matching Python's UserIdentity model" do
      ruby_fields = Supabase::Auth::Types::Identity.members
      python_identity_fields.each do |field|
        expect(ruby_fields).to include(field), "Missing Identity field: #{field}"
      end
    end

    it "UserIdentity has all fields matching Python's UserIdentity model" do
      ruby_fields = Supabase::Auth::Types::UserIdentity.members
      python_identity_fields.each do |field|
        expect(ruby_fields).to include(field), "Missing UserIdentity field: #{field}"
      end
    end

    it "parses Identity from hash correctly" do
      identity = Supabase::Auth::Types::Identity.from_hash({
        "id" => "id1", "identity_id" => "iid1", "user_id" => "u1",
        "identity_data" => { "email" => "test@test.com" },
        "provider" => "google",
        "created_at" => now_iso, "last_sign_in_at" => now_iso, "updated_at" => now_iso
      })
      expect(identity.id).to eq("id1")
      expect(identity.identity_id).to eq("iid1")
      expect(identity.provider).to eq("google")
      expect(identity.identity_data).to eq({ "email" => "test@test.com" })
      expect(identity.created_at).to be_a(Time)
    end

    it "defaults identity_data to empty hash (matches Python Dict[str, Any])" do
      identity = Supabase::Auth::Types::Identity.from_hash({ "id" => "id1", "provider" => "email" })
      expect(identity.identity_data).to eq({})
    end
  end

  # ─── AC-5: All response types have correct fields ───
  describe "AC-5: Response type field parity" do
    it "AuthResponse has user and session fields (matches Python)" do
      expect(Supabase::Auth::Types::AuthResponse.members).to contain_exactly(:user, :session)
    end

    it "AuthResponse.from_hash parses both user and session" do
      resp = Supabase::Auth::Types::AuthResponse.from_hash({
        "user" => { "id" => "u1" },
        "session" => { "access_token" => "at", "refresh_token" => "rt",
                       "token_type" => "bearer", "expires_in" => 3600,
                       "user" => { "id" => "u1" } }
      })
      expect(resp.user).to be_a(Supabase::Auth::Types::User)
      expect(resp.session).to be_a(Supabase::Auth::Types::Session)
    end

    it "AuthOtpResponse has message_id, user, session fields (matches Python)" do
      expect(Supabase::Auth::Types::AuthOtpResponse.members).to contain_exactly(:message_id, :user, :session)
    end

    it "AuthOtpResponse.from_hash handles optional user/session" do
      resp = Supabase::Auth::Types::AuthOtpResponse.from_hash({ "message_id" => "msg-123" })
      expect(resp.message_id).to eq("msg-123")
      expect(resp.user).to be_nil
      expect(resp.session).to be_nil
    end

    it "UserResponse has user field (matches Python)" do
      expect(Supabase::Auth::Types::UserResponse.members).to contain_exactly(:user)
    end

    it "OAuthResponse has provider and url fields (matches Python)" do
      expect(Supabase::Auth::Types::OAuthResponse.members).to contain_exactly(:provider, :url)
    end

    it "SSOResponse has url field (matches Python)" do
      expect(Supabase::Auth::Types::SSOResponse.members).to contain_exactly(:url)
    end

    it "IdentitiesResponse has identities field (matches Python)" do
      expect(Supabase::Auth::Types::IdentitiesResponse.members).to contain_exactly(:identities)
    end

    it "GenerateLinkResponse has properties and user fields (matches Python)" do
      expect(Supabase::Auth::Types::GenerateLinkResponse.members).to contain_exactly(:properties, :user)
    end

    it "GenerateLinkProperties has all fields matching Python" do
      expected = %i[action_link email_otp hashed_token redirect_to verification_type]
      expect(Supabase::Auth::Types::GenerateLinkProperties.members).to contain_exactly(*expected)
    end
  end

  # ─── AC-6: All MFA response types match Python ───
  describe "AC-6: MFA response types" do
    it "AuthMFAEnrollResponse has correct fields (matches Python)" do
      expected = %i[id type friendly_name totp phone]
      expect(Supabase::Auth::Types::AuthMFAEnrollResponse.members).to contain_exactly(*expected)
    end

    it "AuthMFAEnrollResponse.from_hash parses totp with qr_code/secret/uri" do
      resp = Supabase::Auth::Types::AuthMFAEnrollResponse.from_hash({
        "id" => "f1", "type" => "totp", "friendly_name" => "My TOTP",
        "totp" => { "qr_code" => "<svg>...</svg>", "secret" => "JBSWY3DPEHPK3PXP", "uri" => "otpauth://totp/test" }
      })
      expect(resp.id).to eq("f1")
      expect(resp.type).to eq("totp")
      expect(resp.totp).to be_a(Supabase::Auth::Types::AuthMFAEnrollResponseTotp)
      expect(resp.totp.qr_code).to eq("<svg>...</svg>")
      expect(resp.totp.secret).to eq("JBSWY3DPEHPK3PXP")
      expect(resp.totp.uri).to eq("otpauth://totp/test")
    end

    it "AuthMFAEnrollResponseTotp (MFATotpInfo) has qr_code, secret, uri (matches Python)" do
      expected = %i[qr_code secret uri]
      expect(Supabase::Auth::Types::AuthMFAEnrollResponseTotp.members).to contain_exactly(*expected)
    end

    it "MFATotpInfo is aliased to AuthMFAEnrollResponseTotp" do
      expect(Supabase::Auth::Types::MFATotpInfo).to eq(Supabase::Auth::Types::AuthMFAEnrollResponseTotp)
    end

    it "AuthMFAChallengeResponse has correct fields (matches Python)" do
      expected = %i[id factor_type expires_at]
      expect(Supabase::Auth::Types::AuthMFAChallengeResponse.members).to contain_exactly(*expected)
    end

    it "AuthMFAChallengeResponse.from_hash maps 'type' to factor_type (matches Python validation_alias)" do
      resp = Supabase::Auth::Types::AuthMFAChallengeResponse.from_hash({
        "id" => "c1", "type" => "totp", "expires_at" => 1700000000
      })
      expect(resp.factor_type).to eq("totp")
    end

    it "AuthMFAChallengeResponse.from_hash prefers factor_type over type" do
      resp = Supabase::Auth::Types::AuthMFAChallengeResponse.from_hash({
        "id" => "c1", "factor_type" => "phone", "type" => "totp", "expires_at" => 1700000000
      })
      expect(resp.factor_type).to eq("phone")
    end

    it "AuthMFAVerifyResponse has correct fields (matches Python)" do
      expected = %i[access_token token_type expires_in refresh_token user]
      expect(Supabase::Auth::Types::AuthMFAVerifyResponse.members).to contain_exactly(*expected)
    end

    it "AuthMFAVerifyResponse.from_hash parses user" do
      resp = Supabase::Auth::Types::AuthMFAVerifyResponse.from_hash({
        "access_token" => "at", "token_type" => "bearer", "expires_in" => 3600,
        "refresh_token" => "rt", "user" => { "id" => "u1" }
      })
      expect(resp.user).to be_a(Supabase::Auth::Types::User)
      expect(resp.access_token).to eq("at")
    end

    it "AuthMFAUnenrollResponse has id field (matches Python)" do
      expect(Supabase::Auth::Types::AuthMFAUnenrollResponse.members).to contain_exactly(:id)
    end

    it "AuthMFAListFactorsResponse has all/totp/phone fields (matches Python)" do
      expected = %i[all totp phone]
      expect(Supabase::Auth::Types::AuthMFAListFactorsResponse.members).to contain_exactly(*expected)
    end

    it "AuthMFAGetAuthenticatorAssuranceLevelResponse has correct fields (matches Python)" do
      expected = %i[current_level next_level current_authentication_methods]
      expect(Supabase::Auth::Types::AuthMFAGetAuthenticatorAssuranceLevelResponse.members).to contain_exactly(*expected)
    end

    it "AuthMFAAdminListFactorsResponse has factors field (matches Python)" do
      expect(Supabase::Auth::Types::AuthMFAAdminListFactorsResponse.members).to contain_exactly(:factors)
    end

    it "AuthMFAAdminDeleteFactorResponse has id field (matches Python)" do
      expect(Supabase::Auth::Types::AuthMFAAdminDeleteFactorResponse.members).to contain_exactly(:id)
    end

    it "AMREntry has method and timestamp fields (matches Python)" do
      expected = %i[method timestamp]
      expect(Supabase::Auth::Types::AMREntry.members).to contain_exactly(*expected)
    end

    it "AMREntry.from_hash parses correctly" do
      entry = Supabase::Auth::Types::AMREntry.from_hash({ "method" => "password", "timestamp" => 1700000000 })
      expect(entry.method).to eq("password")
      expect(entry.timestamp).to eq(1700000000)
    end
  end

  # ─── AC-7: from_hash methods handle both string and symbol keys ───
  describe "AC-7: from_hash handles both string and symbol keys" do
    it "User.from_hash works with string keys" do
      user = Supabase::Auth::Types::User.from_hash({ "id" => "u1", "email" => "test@test.com" })
      expect(user.id).to eq("u1")
      expect(user.email).to eq("test@test.com")
    end

    it "User.from_hash works with symbol keys" do
      user = Supabase::Auth::Types::User.from_hash({ id: "u1", email: "test@test.com" })
      expect(user.id).to eq("u1")
      expect(user.email).to eq("test@test.com")
    end

    it "Session.from_hash works with string keys" do
      session = Supabase::Auth::Types::Session.from_hash({
        "access_token" => "at", "refresh_token" => "rt",
        "token_type" => "bearer", "expires_in" => 3600,
        "user" => { "id" => "u1" }
      })
      expect(session.access_token).to eq("at")
    end

    it "Session.from_hash works with symbol keys" do
      session = Supabase::Auth::Types::Session.from_hash({
        access_token: "at", refresh_token: "rt",
        token_type: "bearer", expires_in: 3600,
        user: { id: "u1" }
      })
      expect(session.access_token).to eq("at")
    end

    it "Factor.from_hash works with symbol keys" do
      factor = Supabase::Auth::Types::Factor.from_hash({
        id: "f1", factor_type: "totp", status: "verified",
        created_at: now_iso, updated_at: now_iso
      })
      expect(factor.id).to eq("f1")
    end

    it "Identity.from_hash works with symbol keys" do
      identity = Supabase::Auth::Types::Identity.from_hash({
        id: "i1", identity_id: "ii1", user_id: "u1", provider: "email"
      })
      expect(identity.id).to eq("i1")
    end

    it "AuthMFAChallengeResponse.from_hash works with symbol keys" do
      resp = Supabase::Auth::Types::AuthMFAChallengeResponse.from_hash({
        id: "c1", type: "totp", expires_at: 1700000000
      })
      expect(resp.factor_type).to eq("totp")
    end

    it "SSOResponse.from_hash works with symbol keys" do
      resp = Supabase::Auth::Types::SSOResponse.from_hash({ url: "https://sso.example.com" })
      expect(resp.url).to eq("https://sso.example.com")
    end

    it "all from_hash methods return nil for nil input" do
      types_with_from_hash = [
        Supabase::Auth::Types::User,
        Supabase::Auth::Types::Session,
        Supabase::Auth::Types::Factor,
        Supabase::Auth::Types::Identity,
        Supabase::Auth::Types::AuthResponse,
        Supabase::Auth::Types::AuthOtpResponse,
        Supabase::Auth::Types::UserResponse,
        Supabase::Auth::Types::SSOResponse,
        Supabase::Auth::Types::LinkIdentityResponse,
        Supabase::Auth::Types::AuthMFAEnrollResponse,
        Supabase::Auth::Types::AuthMFAChallengeResponse,
        Supabase::Auth::Types::AuthMFAVerifyResponse,
        Supabase::Auth::Types::AuthMFAUnenrollResponse,
        Supabase::Auth::Types::AuthMFAAdminListFactorsResponse,
        Supabase::Auth::Types::AuthMFAAdminDeleteFactorResponse,
        Supabase::Auth::Types::AMREntry,
        Supabase::Auth::Types::UserIdentity
      ]

      types_with_from_hash.each do |type|
        expect(type.from_hash(nil)).to be_nil, "#{type}.from_hash(nil) should return nil"
      end
    end
  end

  # ─── AC-8: Timestamp parsing handles ISO8601 format correctly ───
  describe "AC-8: Timestamp parsing" do
    it "parses ISO8601 timestamp with Z timezone" do
      result = Supabase::Auth::Types.parse_timestamp("2024-01-15T10:30:00Z")
      expect(result).to be_a(Time)
      expect(result.utc.year).to eq(2024)
      expect(result.utc.month).to eq(1)
      expect(result.utc.day).to eq(15)
    end

    it "parses ISO8601 timestamp with offset" do
      result = Supabase::Auth::Types.parse_timestamp("2024-01-15T10:30:00+05:00")
      expect(result).to be_a(Time)
    end

    it "parses ISO8601 timestamp with milliseconds" do
      result = Supabase::Auth::Types.parse_timestamp("2024-01-15T10:30:00.123Z")
      expect(result).to be_a(Time)
    end

    it "returns nil for nil input" do
      expect(Supabase::Auth::Types.parse_timestamp(nil)).to be_nil
    end

    it "returns Time object unchanged" do
      t = Time.now
      expect(Supabase::Auth::Types.parse_timestamp(t)).to equal(t)
    end

    it "handles timestamp without timezone (like Python datetime)" do
      result = Supabase::Auth::Types.parse_timestamp("2024-01-15T10:30:00")
      expect(result).to be_a(Time)
    end
  end

  # ─── Additional: Subscription and ClaimsResponse ───
  describe "Utility types" do
    it "Subscription has id, callback, unsubscribe fields (matches Python)" do
      expected = %i[id callback unsubscribe]
      expect(Supabase::Auth::Types::Subscription.members).to contain_exactly(*expected)
    end

    it "ClaimsResponse has claims, headers, signature fields (matches Python)" do
      expected = %i[claims headers signature]
      expect(Supabase::Auth::Types::ClaimsResponse.members).to contain_exactly(*expected)
    end
  end
end
