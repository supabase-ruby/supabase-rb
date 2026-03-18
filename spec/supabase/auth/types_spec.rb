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
      expect(session.expires_at).to be_a(Time)
      expect(session.expires_at).to eq(Time.at(1_705_312_200))
      expect(session.user).to be_a(Supabase::Auth::Types::User)
      expect(session.user.id).to eq("user-1")
    end

    it "handles nil expires_at" do
      session = described_class.from_hash(
        "access_token" => "token",
        "refresh_token" => "refresh",
        "token_type" => "bearer",
        "expires_in" => 3600,
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
end
