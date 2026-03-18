# frozen_string_literal: true

require "webmock/rspec"

RSpec.describe Supabase::Auth::Client, "Identity Link/Unlink" do
  let(:url) { "http://localhost:9999" }
  let(:headers) { { "apikey" => "test-api-key" } }
  let(:client) { described_class.new(url: url, headers: headers, persist_session: false) }

  let(:fake_session) do
    Supabase::Auth::Types::Session.new(
      access_token: "fake-access-token",
      refresh_token: "fake-refresh-token",
      token_type: "bearer",
      expires_in: 3600,
      expires_at: Time.now.to_i + 3600
    )
  end

  before do
    WebMock.disable_net_connect!
    client.instance_variable_set(:@current_session, fake_session)
  end

  after do
    WebMock.allow_net_connect!
  end

  # -------------------------------------------------------------------
  # AC 1: link_identity returns LinkIdentityResponse with URL
  # -------------------------------------------------------------------
  describe "#link_identity" do
    let(:link_url_pattern) { %r{http://localhost:9999/user/identities/authorize} }
    let(:link_url_exact) { "http://localhost:9999/user/identities/authorize" }
    let(:link_response_body) { { "url" => "https://accounts.google.com/o/oauth2/auth?..." }.to_json }
    let(:link_response_headers) { { "Content-Type" => "application/json" } }

    it "returns LinkIdentityResponse with url" do
      stub_request(:get, link_url_pattern)
        .to_return(status: 200, body: link_response_body, headers: link_response_headers)

      response = client.link_identity(provider: "google")

      expect(response).to be_a(Supabase::Auth::Types::LinkIdentityResponse)
      expect(response.url).to eq("https://accounts.google.com/o/oauth2/auth?...")
    end

    # -------------------------------------------------------------------
    # AC 2: constructs correct /user/identities/authorize URL
    # -------------------------------------------------------------------
    it "constructs correct /user/identities/authorize URL" do
      stub_request(:get, link_url_pattern)
        .to_return(status: 200, body: link_response_body, headers: link_response_headers)

      client.link_identity(provider: "github")

      expect(WebMock).to have_requested(:get, link_url_exact)
        .with(query: hash_including("provider" => "github"))
    end

    # -------------------------------------------------------------------
    # AC 3: includes provider and redirect_to in request
    # -------------------------------------------------------------------
    it "includes provider and redirect_to in the request" do
      stub_request(:get, link_url_pattern)
        .to_return(status: 200, body: link_response_body, headers: link_response_headers)

      client.link_identity(
        provider: "github",
        options: { redirect_to: "http://example.com/callback" }
      )

      expect(WebMock).to have_requested(:get, link_url_exact)
        .with(query: hash_including(
          "provider" => "github",
          "redirect_to" => "http://example.com/callback"
        ))
    end

    it "includes scopes when provided" do
      stub_request(:get, link_url_pattern)
        .to_return(status: 200, body: link_response_body, headers: link_response_headers)

      client.link_identity(
        provider: "google",
        options: { scopes: "openid profile" }
      )

      expect(WebMock).to have_requested(:get, link_url_exact)
        .with(query: hash_including("scopes" => "openid profile"))
    end

    it "always sets skip_http_redirect=true" do
      stub_request(:get, link_url_pattern)
        .to_return(status: 200, body: link_response_body, headers: link_response_headers)

      client.link_identity(provider: "google")

      expect(WebMock).to have_requested(:get, link_url_exact)
        .with(query: hash_including("skip_http_redirect" => "true"))
    end

    it "raises AuthSessionMissing when no session exists" do
      client.instance_variable_set(:@current_session, nil)

      expect {
        client.link_identity(provider: "google")
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end

    it "sends the session access_token as Bearer authorization" do
      stub_request(:get, link_url_pattern)
        .to_return(status: 200, body: link_response_body, headers: link_response_headers)

      client.link_identity(provider: "google")

      expect(WebMock).to have_requested(:get, link_url_pattern)
        .with(headers: { "Authorization" => "Bearer fake-access-token" })
    end
  end

  # -------------------------------------------------------------------
  # AC 4: unlink_identity sends DELETE to /user/identities/{id}
  # -------------------------------------------------------------------
  describe "#unlink_identity" do
    let(:identity_struct) do
      Supabase::Auth::Types::UserIdentity.new(
        id: "uuid-123",
        identity_id: "identity-456",
        user_id: "user-789",
        provider: "github"
      )
    end

    it "sends DELETE to /user/identities/{identity_id}" do
      stub_request(:delete, "http://localhost:9999/user/identities/identity-456")
        .to_return(status: 200, body: "".to_json, headers: { "Content-Type" => "application/json" })

      client.unlink_identity(identity_struct)

      expect(WebMock).to have_requested(:delete, "http://localhost:9999/user/identities/identity-456")
    end

    it "sends Bearer token from current session" do
      stub_request(:delete, "http://localhost:9999/user/identities/identity-456")
        .to_return(status: 200, body: "".to_json, headers: { "Content-Type" => "application/json" })

      client.unlink_identity(identity_struct)

      expect(WebMock).to have_requested(:delete, "http://localhost:9999/user/identities/identity-456")
        .with(headers: { "Authorization" => "Bearer fake-access-token" })
    end

    # -------------------------------------------------------------------
    # AC 5: unlink_identity works with hash input
    # -------------------------------------------------------------------
    it "accepts a hash with identity_id" do
      stub_request(:delete, "http://localhost:9999/user/identities/hash-identity-id")
        .to_return(status: 200, body: "".to_json, headers: { "Content-Type" => "application/json" })

      client.unlink_identity(identity_id: "hash-identity-id")

      expect(WebMock).to have_requested(:delete, "http://localhost:9999/user/identities/hash-identity-id")
    end

    it "raises AuthSessionMissing when no session exists" do
      client.instance_variable_set(:@current_session, nil)

      expect {
        client.unlink_identity(identity_struct)
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end
  end

  # -------------------------------------------------------------------
  # AC 6: get_user_identities returns list of UserIdentity objects
  # -------------------------------------------------------------------
  describe "#get_user_identities" do
    let(:user_response_body) do
      {
        "id" => "user-789",
        "email" => "test@example.com",
        "identities" => [
          {
            "id" => "id-1",
            "identity_id" => "identity-1",
            "user_id" => "user-789",
            "provider" => "github",
            "identity_data" => { "email" => "test@github.com" },
            "created_at" => "2024-01-01T00:00:00Z",
            "last_sign_in_at" => "2024-06-01T00:00:00Z",
            "updated_at" => "2024-06-01T00:00:00Z"
          },
          {
            "id" => "id-2",
            "identity_id" => "identity-2",
            "user_id" => "user-789",
            "provider" => "google",
            "identity_data" => { "email" => "test@gmail.com" },
            "created_at" => "2024-02-01T00:00:00Z",
            "last_sign_in_at" => "2024-06-15T00:00:00Z",
            "updated_at" => "2024-06-15T00:00:00Z"
          }
        ]
      }
    end

    it "returns IdentitiesResponse with list of identities" do
      stub_request(:get, "http://localhost:9999/user")
        .to_return(status: 200, body: user_response_body.to_json, headers: { "Content-Type" => "application/json" })

      result = client.get_user_identities

      expect(result).to be_a(Supabase::Auth::Types::IdentitiesResponse)
      expect(result.identities.length).to eq(2)
    end

    it "returns identities with correct provider names" do
      stub_request(:get, "http://localhost:9999/user")
        .to_return(status: 200, body: user_response_body.to_json, headers: { "Content-Type" => "application/json" })

      result = client.get_user_identities
      providers = result.identities.map(&:provider)

      expect(providers).to contain_exactly("github", "google")
    end

    it "returns identities with identity_id fields" do
      stub_request(:get, "http://localhost:9999/user")
        .to_return(status: 200, body: user_response_body.to_json, headers: { "Content-Type" => "application/json" })

      result = client.get_user_identities
      identity_ids = result.identities.map(&:identity_id)

      expect(identity_ids).to contain_exactly("identity-1", "identity-2")
    end

    it "returns empty identities when user has none" do
      stub_request(:get, "http://localhost:9999/user")
        .to_return(
          status: 200,
          body: { "id" => "user-789", "email" => "test@example.com", "identities" => [] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = client.get_user_identities

      expect(result.identities).to eq([])
    end

    it "raises AuthSessionMissing when no session exists" do
      client.instance_variable_set(:@current_session, nil)

      expect {
        client.get_user_identities
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end
  end
end
