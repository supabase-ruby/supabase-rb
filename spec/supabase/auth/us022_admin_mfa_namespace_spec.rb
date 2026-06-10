# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "json"
require "securerandom"

# US-022: Auth admin MFA namespace (F-C9)
# Pins the new `admin.mfa.list_factors` / `admin.mfa.delete_factor` namespace
# (mirrors supabase-py's SyncGoTrueAdminMFAAPI) and the bare-array response
# form returned by current GoTrue.
RSpec.describe "US-022: Admin MFA namespace" do
  let(:base_url) { "http://localhost:9998" }
  let(:admin_api) do
    Supabase::Auth::AdminApi.new(
      url: base_url,
      headers: { "Authorization" => "Bearer service-role-jwt" }
    )
  end

  let(:test_uuid) { "550e8400-e29b-41d4-a716-446655440000" }
  let(:test_factor_id) { "660e8400-e29b-41d4-a716-446655440000" }

  let(:mock_factor) do
    {
      "id" => test_factor_id,
      "friendly_name" => "My TOTP",
      "factor_type" => "totp",
      "status" => "verified",
      "created_at" => "2023-01-01T00:00:00Z",
      "updated_at" => "2023-01-01T00:00:00Z"
    }
  end

  before do
    WebMock.disable_net_connect!
  end

  after do
    WebMock.allow_net_connect!
  end

  describe "#mfa accessor (AC #2)" do
    it "exposes AdminMfaApi via attr_reader :mfa" do
      expect(admin_api.mfa).to be_a(Supabase::Auth::AdminMfaApi)
    end

    it "memoizes the same instance across calls" do
      expect(admin_api.mfa).to equal(admin_api.mfa)
    end
  end

  describe "#mfa.list_factors (AC #1, #6)" do
    it "returns parsed factors when GoTrue responds with a bare JSON array" do
      stub = stub_request(:get, "#{base_url}/admin/users/#{test_uuid}/factors")
        .to_return(
          status: 200,
          body: [mock_factor].to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = admin_api.mfa.list_factors(user_id: test_uuid)
      expect(stub).to have_been_requested
      expect(result).to be_a(Supabase::Auth::Types::AuthMFAAdminListFactorsResponse)
      expect(result.factors.size).to eq(1)
      expect(result.factors.first.id).to eq(test_factor_id)
      expect(result.factors.first.factor_type).to eq("totp")
    end

    it "also accepts the legacy `{\"factors\": [...]}` wrapped form (AC #4)" do
      stub_request(:get, "#{base_url}/admin/users/#{test_uuid}/factors")
        .to_return(
          status: 200,
          body: { "factors" => [mock_factor] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = admin_api.mfa.list_factors(user_id: test_uuid)
      expect(result.factors.size).to eq(1)
      expect(result.factors.first.id).to eq(test_factor_id)
    end

    it "validates user_id UUID" do
      expect {
        admin_api.mfa.list_factors(user_id: "not-a-uuid")
      }.to raise_error(ArgumentError, /Invalid id/)
    end
  end

  describe "#mfa.delete_factor (AC #1)" do
    it "sends DELETE to /admin/users/{user_id}/factors/{id}" do
      stub = stub_request(:delete, "#{base_url}/admin/users/#{test_uuid}/factors/#{test_factor_id}")
        .to_return(
          status: 200,
          body: { "id" => test_factor_id }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = admin_api.mfa.delete_factor(user_id: test_uuid, id: test_factor_id)
      expect(stub).to have_been_requested
      expect(result).to be_a(Supabase::Auth::Types::AuthMFAAdminDeleteFactorResponse)
      expect(result.id).to eq(test_factor_id)
    end

    it "validates user_id UUID" do
      expect {
        admin_api.mfa.delete_factor(user_id: "bad", id: test_factor_id)
      }.to raise_error(ArgumentError, /Invalid id, 'bad'/)
    end

    it "validates factor id UUID" do
      expect {
        admin_api.mfa.delete_factor(user_id: test_uuid, id: "bad")
      }.to raise_error(ArgumentError, /Invalid id, 'bad'/)
    end
  end

  describe "AuthMFAAdminListFactorsResponse.from_hash (AC #4)" do
    it "accepts a bare Array of factor hashes" do
      result = Supabase::Auth::Types::AuthMFAAdminListFactorsResponse.from_hash([mock_factor])
      expect(result.factors.size).to eq(1)
      expect(result.factors.first.id).to eq(test_factor_id)
    end

    it "accepts a Hash wrapping factors under the \"factors\" key" do
      result = Supabase::Auth::Types::AuthMFAAdminListFactorsResponse.from_hash("factors" => [mock_factor])
      expect(result.factors.size).to eq(1)
    end

    it "returns nil for nil input" do
      expect(Supabase::Auth::Types::AuthMFAAdminListFactorsResponse.from_hash(nil)).to be_nil
    end

    it "returns empty factors for an empty array" do
      result = Supabase::Auth::Types::AuthMFAAdminListFactorsResponse.from_hash([])
      expect(result.factors).to eq([])
    end
  end
end
