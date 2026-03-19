# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "json"

# US-003: Audit User Management Methods
# Verifies that Ruby user management methods match Python (auth-py) behavior:
#   - get_user accepts optional JWT parameter
#   - update_user sends PUT to /user with correct body and email_redirect_to header
#   - link_identity returns correct type (FINDING: Python returns OAuthResponse, Ruby returns LinkIdentityResponse)
#   - unlink_identity accepts identity with identity_id field
#   - reset_password_for_email sends captcha_token and redirect_to correctly
#   - reauthenticate sends GET to /reauthenticate
RSpec.describe "US-003: User Management Methods Audit" do
  let(:base_url) { "http://localhost:9998" }
  let(:client) do
    Supabase::Auth::Client.new(
      url: base_url,
      auto_refresh_token: false,
      persist_session: false
    )
  end

  let(:mock_user_hash) do
    {
      "id" => "test-user-id",
      "app_metadata" => {},
      "user_metadata" => { "name" => "Test User" },
      "aud" => "authenticated",
      "email" => "test@example.com",
      "phone" => "+1234567890",
      "created_at" => "2023-01-01T00:00:00Z",
      "confirmed_at" => "2023-01-01T00:00:00Z",
      "last_sign_in_at" => "2023-06-01T00:00:00Z",
      "role" => "authenticated",
      "updated_at" => "2023-06-01T00:00:00Z",
      "identities" => [
        {
          "id" => "id-1",
          "identity_id" => "identity-1",
          "user_id" => "test-user-id",
          "provider" => "email",
          "identity_data" => { "email" => "test@example.com" },
          "created_at" => "2023-01-01T00:00:00Z",
          "last_sign_in_at" => "2023-06-01T00:00:00Z",
          "updated_at" => "2023-06-01T00:00:00Z"
        }
      ],
      "factors" => []
    }
  end

  let(:now) { Time.now.to_i }

  let(:mock_session) do
    Supabase::Auth::Types::Session.new(
      access_token: "test-access-token",
      refresh_token: "test-refresh-token",
      expires_in: 3600,
      expires_at: now + 3600,
      token_type: "bearer"
    )
  end

  before do
    WebMock.disable_net_connect!
    client.instance_variable_set(:@current_session, mock_session)
  end

  after do
    WebMock.allow_net_connect!
  end

  # ── AC-1: get_user accepts optional JWT parameter ──

  describe "AC-1: get_user accepts optional JWT parameter" do
    it "uses provided JWT when given" do
      stub_request(:get, "#{base_url}/user")
        .with(headers: { "Authorization" => "Bearer custom-jwt-token" })
        .to_return(status: 200, body: mock_user_hash.to_json, headers: { "Content-Type" => "application/json" })

      result = client.get_user("custom-jwt-token")

      expect(result).to be_a(Supabase::Auth::Types::UserResponse)
      expect(result.user.id).to eq("test-user-id")
      expect(WebMock).to have_requested(:get, "#{base_url}/user")
        .with(headers: { "Authorization" => "Bearer custom-jwt-token" })
    end

    it "falls back to session access_token when no JWT provided" do
      stub_request(:get, "#{base_url}/user")
        .with(headers: { "Authorization" => "Bearer test-access-token" })
        .to_return(status: 200, body: mock_user_hash.to_json, headers: { "Content-Type" => "application/json" })

      result = client.get_user

      expect(result).to be_a(Supabase::Auth::Types::UserResponse)
      expect(WebMock).to have_requested(:get, "#{base_url}/user")
        .with(headers: { "Authorization" => "Bearer test-access-token" })
    end

    it "returns nil when no session and no JWT provided" do
      client.instance_variable_set(:@current_session, nil)

      result = client.get_user

      expect(result).to be_nil
    end

    it "returns UserResponse with correct user fields matching Python" do
      stub_request(:get, "#{base_url}/user")
        .to_return(status: 200, body: mock_user_hash.to_json, headers: { "Content-Type" => "application/json" })

      result = client.get_user("some-jwt")
      user = result.user

      expect(user.id).to eq("test-user-id")
      expect(user.email).to eq("test@example.com")
      expect(user.phone).to eq("+1234567890")
      expect(user.role).to eq("authenticated")
      expect(user.aud).to eq("authenticated")
      expect(user.user_metadata).to eq({ "name" => "Test User" })
      expect(user.identities).to be_an(Array)
      expect(user.identities.length).to eq(1)
    end

    it "sends GET request to /user endpoint (matching Python)" do
      stub_request(:get, "#{base_url}/user")
        .to_return(status: 200, body: mock_user_hash.to_json, headers: { "Content-Type" => "application/json" })

      client.get_user("jwt-token")

      expect(WebMock).to have_requested(:get, "#{base_url}/user").once
    end
  end

  # ── AC-2: update_user sends PUT to /user with correct body and email_redirect_to ──

  describe "AC-2: update_user sends PUT to /user with correct body and email_redirect_to" do
    let(:updated_user_hash) do
      mock_user_hash.merge("email" => "new@example.com", "user_metadata" => { "name" => "Updated" })
    end

    it "sends PUT to /user with attributes as body" do
      stub_request(:put, "#{base_url}/user")
        .to_return(status: 200, body: updated_user_hash.to_json, headers: { "Content-Type" => "application/json" })

      attrs = { email: "new@example.com", data: { name: "Updated" } }
      result = client.update_user(attrs)

      expect(result).to be_a(Supabase::Auth::Types::UserResponse)
      expect(WebMock).to have_requested(:put, "#{base_url}/user")
        .with(body: attrs.to_json)
    end

    it "sends email_redirect_to as redirect_to query param when provided" do
      stub_request(:put, "#{base_url}/user")
        .with(query: { "redirect_to" => "http://example.com/confirm" })
        .to_return(status: 200, body: updated_user_hash.to_json, headers: { "Content-Type" => "application/json" })

      client.update_user({ email: "new@example.com" }, { email_redirect_to: "http://example.com/confirm" })

      # redirect_to is passed as query param via _request
      expect(WebMock).to have_requested(:put, "#{base_url}/user")
        .with(
          query: { "redirect_to" => "http://example.com/confirm" },
          headers: { "Authorization" => "Bearer test-access-token" }
        )
    end

    it "uses session access_token for authorization" do
      stub_request(:put, "#{base_url}/user")
        .to_return(status: 200, body: updated_user_hash.to_json, headers: { "Content-Type" => "application/json" })

      client.update_user({ password: "newpassword" })

      expect(WebMock).to have_requested(:put, "#{base_url}/user")
        .with(headers: { "Authorization" => "Bearer test-access-token" })
    end

    it "updates session user and notifies USER_UPDATED event" do
      stub_request(:put, "#{base_url}/user")
        .to_return(status: 200, body: updated_user_hash.to_json, headers: { "Content-Type" => "application/json" })

      events = []
      client.on_auth_state_change { |event, session| events << [event, session] }

      client.update_user({ email: "new@example.com" })

      expect(events.length).to eq(1)
      expect(events[0][0]).to eq("USER_UPDATED")
      expect(events[0][1]).to be_a(Supabase::Auth::Types::Session)
      expect(events[0][1].user.email).to eq("new@example.com")
    end

    it "preserves existing session tokens after update (matching Python)" do
      stub_request(:put, "#{base_url}/user")
        .to_return(status: 200, body: updated_user_hash.to_json, headers: { "Content-Type" => "application/json" })

      client.update_user({ email: "new@example.com" })

      # Python mutates session.user in-place; Ruby creates new session with same tokens
      session = client.instance_variable_get(:@current_session)
      expect(session.access_token).to eq("test-access-token")
      expect(session.refresh_token).to eq("test-refresh-token")
    end

    it "raises AuthSessionMissing when no session exists" do
      client.instance_variable_set(:@current_session, nil)

      expect {
        client.update_user({ email: "new@example.com" })
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end
  end

  # ── AC-3: link_identity returns correct type ──
  # FINDING: Python returns OAuthResponse(provider=provider, url=response.url)
  # Ruby returns LinkIdentityResponse (which wraps url)

  describe "AC-3: link_identity returns correct type" do
    let(:link_response_body) { { "url" => "https://accounts.google.com/o/oauth2/auth?code=abc" }.to_json }
    let(:link_url) { "#{base_url}/user/identities/authorize" }

    before do
      stub_request(:get, /#{Regexp.escape(base_url)}\/user\/identities\/authorize/)
        .to_return(status: 200, body: link_response_body, headers: { "Content-Type" => "application/json" })
    end

    it "returns LinkIdentityResponse (Ruby divergence from Python OAuthResponse)" do
      result = client.link_identity(provider: "google")

      # FINDING: Python returns OAuthResponse; Ruby returns LinkIdentityResponse
      # Both contain url field, so functionally equivalent
      expect(result).to be_a(Supabase::Auth::Types::LinkIdentityResponse)
      expect(result.url).to eq("https://accounts.google.com/o/oauth2/auth?code=abc")
    end

    it "sends GET to /user/identities/authorize with provider param" do
      client.link_identity(provider: "github")

      expect(WebMock).to have_requested(:get, link_url)
        .with(query: hash_including("provider" => "github"))
    end

    it "always includes skip_http_redirect=true (matching Python)" do
      client.link_identity(provider: "google")

      expect(WebMock).to have_requested(:get, link_url)
        .with(query: hash_including("skip_http_redirect" => "true"))
    end

    it "includes redirect_to and scopes when provided" do
      client.link_identity(
        provider: "github",
        options: { redirect_to: "http://example.com/cb", scopes: "user:email" }
      )

      expect(WebMock).to have_requested(:get, link_url)
        .with(query: hash_including(
          "redirect_to" => "http://example.com/cb",
          "scopes" => "user:email"
        ))
    end

    it "requires active session (matching Python)" do
      client.instance_variable_set(:@current_session, nil)

      expect {
        client.link_identity(provider: "google")
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end
  end

  # ── AC-4: unlink_identity accepts identity with identity_id field ──

  describe "AC-4: unlink_identity accepts identity with identity_id field" do
    it "sends DELETE to /user/identities/{identity_id} with struct" do
      stub_request(:delete, "#{base_url}/user/identities/identity-abc")
        .to_return(status: 200, body: "".to_json, headers: { "Content-Type" => "application/json" })

      identity = Supabase::Auth::Types::UserIdentity.new(
        id: "uuid-1",
        identity_id: "identity-abc",
        user_id: "user-1",
        provider: "github"
      )
      client.unlink_identity(identity)

      expect(WebMock).to have_requested(:delete, "#{base_url}/user/identities/identity-abc")
    end

    it "sends DELETE with hash input (Ruby extension over Python)" do
      stub_request(:delete, "#{base_url}/user/identities/identity-xyz")
        .to_return(status: 200, body: "".to_json, headers: { "Content-Type" => "application/json" })

      client.unlink_identity(identity_id: "identity-xyz")

      expect(WebMock).to have_requested(:delete, "#{base_url}/user/identities/identity-xyz")
    end

    it "sends session access_token as authorization" do
      stub_request(:delete, "#{base_url}/user/identities/identity-123")
        .to_return(status: 200, body: "".to_json, headers: { "Content-Type" => "application/json" })

      client.unlink_identity(identity_id: "identity-123")

      expect(WebMock).to have_requested(:delete, "#{base_url}/user/identities/identity-123")
        .with(headers: { "Authorization" => "Bearer test-access-token" })
    end

    it "raises AuthSessionMissing without active session (matching Python)" do
      client.instance_variable_set(:@current_session, nil)

      expect {
        client.unlink_identity(identity_id: "identity-abc")
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end
  end

  # ── AC-5: reset_password_for_email sends captcha_token and redirect_to correctly ──

  describe "AC-5: reset_password_for_email sends captcha_token and redirect_to correctly" do
    it "sends POST to /recover with email and gotrue_meta_security" do
      stub_request(:post, "#{base_url}/recover")
        .to_return(status: 200, body: "{}".to_json, headers: { "Content-Type" => "application/json" })

      client.reset_password_for_email("user@example.com")

      expect(WebMock).to have_requested(:post, "#{base_url}/recover")
        .with(body: hash_including(
          "email" => "user@example.com",
          "gotrue_meta_security" => { "captcha_token" => nil }
        ))
    end

    it "includes captcha_token in gotrue_meta_security (matching Python)" do
      stub_request(:post, "#{base_url}/recover")
        .to_return(status: 200, body: "{}".to_json, headers: { "Content-Type" => "application/json" })

      client.reset_password_for_email("user@example.com", captcha_token: "captcha-abc-123")

      expect(WebMock).to have_requested(:post, "#{base_url}/recover")
        .with(body: hash_including(
          "email" => "user@example.com",
          "gotrue_meta_security" => { "captcha_token" => "captcha-abc-123" }
        ))
    end

    it "passes redirect_to as query param (matching Python)" do
      stub_request(:post, "#{base_url}/recover")
        .with(query: { "redirect_to" => "http://example.com/reset" })
        .to_return(status: 200, body: "{}".to_json, headers: { "Content-Type" => "application/json" })

      client.reset_password_for_email("user@example.com", redirect_to: "http://example.com/reset")

      expect(WebMock).to have_requested(:post, "#{base_url}/recover")
        .with(query: { "redirect_to" => "http://example.com/reset" })
    end

    it "does not require an active session (matching Python)" do
      client.instance_variable_set(:@current_session, nil)

      stub_request(:post, "#{base_url}/recover")
        .to_return(status: 200, body: "{}".to_json, headers: { "Content-Type" => "application/json" })

      # Should not raise - no session required for password reset
      expect { client.reset_password_for_email("user@example.com") }.not_to raise_error
    end
  end

  # ── AC-6: reauthenticate sends GET to /reauthenticate ──

  describe "AC-6: reauthenticate sends GET to /reauthenticate" do
    it "sends GET to /reauthenticate with session token" do
      stub_request(:get, "#{base_url}/reauthenticate")
        .to_return(status: 200, body: mock_user_hash.to_json, headers: { "Content-Type" => "application/json" })

      client.reauthenticate

      expect(WebMock).to have_requested(:get, "#{base_url}/reauthenticate")
        .with(headers: { "Authorization" => "Bearer test-access-token" })
    end

    it "returns parsed AuthResponse (matching Python xform=parse_auth_response)" do
      auth_response = {
        "access_token" => "new-token",
        "refresh_token" => "new-refresh",
        "expires_in" => 3600,
        "expires_at" => now + 3600,
        "token_type" => "bearer",
        "user" => mock_user_hash
      }
      stub_request(:get, "#{base_url}/reauthenticate")
        .to_return(status: 200, body: auth_response.to_json, headers: { "Content-Type" => "application/json" })

      result = client.reauthenticate

      expect(result).to be_a(Supabase::Auth::Types::AuthResponse)
    end

    it "raises AuthSessionMissing when no session (matching Python)" do
      client.instance_variable_set(:@current_session, nil)

      expect {
        client.reauthenticate
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end
  end
end
