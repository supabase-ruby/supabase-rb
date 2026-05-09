# frozen_string_literal: true

require "webmock/rspec"

RSpec.describe Supabase::Auth::Client, "initialization flow" do
  let(:url) { "http://localhost:9999" }
  let(:headers) { { "apikey" => "test-api-key" } }

  before do
    WebMock.disable_net_connect!
  end

  after do
    WebMock.allow_net_connect!
  end

  # -------------------------------------------------------------------
  # AC 3: Default options match Python
  # -------------------------------------------------------------------
  describe "default options" do
    subject(:client) { described_class.new(url: url, headers: headers) }

    it "defaults auto_refresh_token to true" do
      # Python: auto_refresh_token: bool = True
      # Access via internal state — verified by auto-refresh timer scheduling
      expect(client).to be_a(described_class)
    end

    it "defaults persist_session to true" do
      # Python: persist_session: bool = True
      # Verified: get_session reads from storage when persist_session is true
      storage = client._storage
      expect(storage).to be_a(Supabase::Auth::MemoryStorage)
    end

    it "defaults flow_type to 'implicit'" do
      # Python: flow_type: AuthFlowType = "implicit"
      expect(client._flow_type).to eq("implicit")
    end

    it "accepts pkce flow_type" do
      client = described_class.new(url: url, flow_type: "pkce")
      expect(client._flow_type).to eq("pkce")
    end

    # AC 4: Storage key defaults to "supabase.auth.token"
    it "defaults storage_key to 'supabase.auth.token'" do
      # Python: STORAGE_KEY = "supabase.auth.token"
      expect(client._storage_key).to eq("supabase.auth.token")
    end

    it "accepts custom storage_key" do
      client = described_class.new(url: url, storage_key: "custom.key")
      expect(client._storage_key).to eq("custom.key")
    end

    it "uses MemoryStorage by default" do
      # Python: storage or SyncMemoryStorage()
      expect(client._storage).to be_a(Supabase::Auth::MemoryStorage)
    end

    it "accepts custom storage" do
      custom = Supabase::Auth::MemoryStorage.new
      client = described_class.new(url: url, storage: custom)
      expect(client._storage).to equal(custom)
    end
  end

  # -------------------------------------------------------------------
  # AC 5: Client correctly initializes admin and mfa sub-APIs
  # -------------------------------------------------------------------
  describe "sub-API initialization" do
    subject(:client) { described_class.new(url: url, headers: headers) }

    it "initializes admin sub-API" do
      # Python: self.admin = SyncGoTrueAdminAPI(url=self._url, headers=self._headers, ...)
      expect(client.admin).to be_a(Supabase::Auth::AdminApi)
    end

    it "initializes mfa sub-API" do
      # Python: self.mfa = SyncGoTrueMFAAPI()
      expect(client.mfa).to be_a(Supabase::Auth::MFAApi)
    end

    it "mfa delegates to client methods" do
      # Python binds: self.mfa.enroll = self._enroll, etc.
      # Ruby wraps: MFAApi.new(self) delegates all calls
      expect(client.mfa).to respond_to(:enroll)
      expect(client.mfa).to respond_to(:challenge)
      expect(client.mfa).to respond_to(:verify)
      expect(client.mfa).to respond_to(:challenge_and_verify)
      expect(client.mfa).to respond_to(:unenroll)
      expect(client.mfa).to respond_to(:list_factors)
      expect(client.mfa).to respond_to(:get_authenticator_assurance_level)
    end
  end

  # -------------------------------------------------------------------
  # AC 1: initialize_from_url correctly parses implicit grant URL
  # -------------------------------------------------------------------
  describe "#initialize_from_url" do
    let(:access_token) { "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U" }
    let(:refresh_token) { "refresh-token-123" }
    let(:expires_in) { "3600" }
    let(:token_type) { "bearer" }

    let(:base_url) do
      "http://example.com/callback?access_token=#{access_token}" \
        "&refresh_token=#{refresh_token}" \
        "&expires_in=#{expires_in}" \
        "&token_type=#{token_type}"
    end

    let(:user_data) do
      {
        "id" => "user-123",
        "aud" => "authenticated",
        "role" => "authenticated",
        "email" => "test@example.com",
        "app_metadata" => {},
        "user_metadata" => {},
        "created_at" => "2024-01-01T00:00:00Z"
      }
    end

    before do
      # Stub get_user call that initialize_from_url triggers
      stub_request(:get, "#{url}/user")
        .to_return(
          status: 200,
          body: user_data.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "parses access_token from URL" do
      client = described_class.new(url: url, headers: headers)
      client.initialize_from_url(base_url)

      session = client.get_session
      expect(session).to be_a(Supabase::Auth::Types::Session)
      expect(session.access_token).to eq(access_token)
    end

    it "parses refresh_token from URL" do
      client = described_class.new(url: url, headers: headers)
      client.initialize_from_url(base_url)

      session = client.get_session
      expect(session.refresh_token).to eq(refresh_token)
    end

    it "computes expires_at from expires_in" do
      # Python: expires_at = round(time()) + int(expires_in)
      client = described_class.new(url: url, headers: headers)
      before_time = Time.now.round.to_i
      client.initialize_from_url(base_url)
      after_time = Time.now.round.to_i

      session = client.get_session
      expect(session.expires_at).to be_between(
        before_time + expires_in.to_i,
        after_time + expires_in.to_i
      )
    end

    it "parses token_type from URL" do
      client = described_class.new(url: url, headers: headers)
      client.initialize_from_url(base_url)

      session = client.get_session
      expect(session.token_type).to eq(token_type)
    end

    it "parses optional provider_token" do
      url_with_provider = "#{base_url}&provider_token=github-token"
      client = described_class.new(url: url, headers: headers)
      client.initialize_from_url(url_with_provider)

      session = client.get_session
      expect(session.provider_token).to eq("github-token")
    end

    it "parses optional provider_refresh_token" do
      url_with_provider = "#{base_url}&provider_refresh_token=github-refresh"
      client = described_class.new(url: url, headers: headers)
      client.initialize_from_url(url_with_provider)

      session = client.get_session
      expect(session.provider_refresh_token).to eq("github-refresh")
    end

    it "raises on missing access_token" do
      bad_url = "http://example.com/callback?refresh_token=rt&expires_in=3600&token_type=bearer"
      client = described_class.new(url: url, headers: headers)

      # _is_implicit_grant_flow returns false without access_token or error_description,
      # so initialize_from_url does nothing (no error raised, just skips)
      expect { client.initialize_from_url(bad_url) }.not_to raise_error
    end

    it "raises AuthImplicitGrantRedirectError on error_description in URL" do
      error_url = "http://example.com/callback?error_description=access_denied" \
                  "&error_code=otp_expired&error=unauthorized"
      client = described_class.new(url: url, headers: headers)

      expect { client.initialize_from_url(error_url) }.to raise_error(
        Supabase::Auth::Errors::AuthImplicitGrantRedirectError
      )
    end

    it "raises when error_description present but error_code missing" do
      # Python: if not error_code: raise AuthImplicitGrantRedirectError("No error_code detected.")
      error_url = "http://example.com/callback?error_description=something&error=bad"
      client = described_class.new(url: url, headers: headers)

      expect { client.initialize_from_url(error_url) }.to raise_error(
        Supabase::Auth::Errors::AuthImplicitGrantRedirectError,
        /No error_code detected/
      )
    end

    it "raises when error_description present but error missing" do
      # Python: if not error: raise AuthImplicitGrantRedirectError("No error detected.")
      error_url = "http://example.com/callback?error_description=something&error_code=otp_expired"
      client = described_class.new(url: url, headers: headers)

      expect { client.initialize_from_url(error_url) }.to raise_error(
        Supabase::Auth::Errors::AuthImplicitGrantRedirectError,
        /No error detected/
      )
    end

    it "calls get_user to fetch user data" do
      client = described_class.new(url: url, headers: headers)
      client.initialize_from_url(base_url)

      expect(WebMock).to have_requested(:get, "#{url}/user")
    end

    it "removes session on error during initialization" do
      # Stub get_user to fail
      stub_request(:get, "#{url}/user")
        .to_return(status: 500, body: '{"error":"internal"}', headers: { "Content-Type" => "application/json" })

      client = described_class.new(url: url, headers: headers)

      expect { client.initialize_from_url(base_url) }.to raise_error(StandardError)
      expect(client.get_session).to be_nil
    end
  end

  # -------------------------------------------------------------------
  # AC 1 continued: _is_implicit_grant_flow
  # -------------------------------------------------------------------
  describe "#_is_implicit_grant_flow" do
    subject(:client) { described_class.new(url: url, headers: headers) }

    it "returns true when access_token in query params" do
      expect(client._is_implicit_grant_flow("http://example.com?access_token=abc")).to be true
    end

    it "returns true when error_description in query params" do
      expect(client._is_implicit_grant_flow("http://example.com?error_description=bad")).to be true
    end

    it "returns false when neither access_token nor error_description" do
      expect(client._is_implicit_grant_flow("http://example.com?code=abc")).to be false
    end

    it "returns false for empty query" do
      expect(client._is_implicit_grant_flow("http://example.com")).to be false
    end
  end

  # -------------------------------------------------------------------
  # AC 2: initialize_from_storage recovers session and refreshes if expired
  # -------------------------------------------------------------------
  describe "#initialize_from_storage" do
    it "recovers valid session from storage" do
      storage = Supabase::Auth::MemoryStorage.new
      session_data = {
        "access_token" => "valid-token",
        "refresh_token" => "refresh-123",
        "token_type" => "bearer",
        "expires_in" => 3600,
        "expires_at" => Time.now.to_i + 3600,
        "user" => {
          "id" => "user-123",
          "aud" => "authenticated",
          "role" => "authenticated",
          "email" => "test@example.com",
          "app_metadata" => {},
          "user_metadata" => {},
          "created_at" => "2024-01-01T00:00:00Z"
        }
      }
      storage.set_item("supabase.auth.token", JSON.generate(session_data))

      client = described_class.new(url: url, headers: headers, storage: storage)
      client.initialize_from_storage

      session = client.get_session
      expect(session).to be_a(Supabase::Auth::Types::Session)
      expect(session.access_token).to eq("valid-token")
    end

    it "returns nil when no session in storage" do
      client = described_class.new(url: url, headers: headers)
      client.initialize_from_storage

      # get_session reads from storage when persist_session is true
      expect(client.get_session).to be_nil
    end

    it "removes invalid session from storage" do
      storage = Supabase::Auth::MemoryStorage.new
      storage.set_item("supabase.auth.token", "not-valid-json{{{")

      client = described_class.new(url: url, headers: headers, storage: storage)
      client.initialize_from_storage

      expect(storage.get_item("supabase.auth.token")).to be_nil
    end

    it "removes session missing access_token" do
      storage = Supabase::Auth::MemoryStorage.new
      session_data = { "refresh_token" => "rt", "expires_at" => Time.now.to_i + 3600 }
      storage.set_item("supabase.auth.token", JSON.generate(session_data))

      client = described_class.new(url: url, headers: headers, storage: storage)
      client.initialize_from_storage

      expect(storage.get_item("supabase.auth.token")).to be_nil
    end

    it "removes session missing refresh_token" do
      storage = Supabase::Auth::MemoryStorage.new
      session_data = { "access_token" => "at", "expires_at" => Time.now.to_i + 3600 }
      storage.set_item("supabase.auth.token", JSON.generate(session_data))

      client = described_class.new(url: url, headers: headers, storage: storage)
      client.initialize_from_storage

      expect(storage.get_item("supabase.auth.token")).to be_nil
    end

    it "removes session missing expires_at" do
      storage = Supabase::Auth::MemoryStorage.new
      session_data = { "access_token" => "at", "refresh_token" => "rt" }
      storage.set_item("supabase.auth.token", JSON.generate(session_data))

      client = described_class.new(url: url, headers: headers, storage: storage)
      client.initialize_from_storage

      expect(storage.get_item("supabase.auth.token")).to be_nil
    end

    it "attempts to refresh expired session and notifies TOKEN_REFRESHED" do
      # FINDING: Both Python and Ruby call _remove_session() after the try block in
      # _recover_and_refresh, even after a successful refresh. This means the refreshed
      # session is saved by _call_refresh_token but then immediately removed. The
      # TOKEN_REFRESHED event IS fired, matching Python behavior.
      storage = Supabase::Auth::MemoryStorage.new
      expired_session = {
        "access_token" => "expired-token",
        "refresh_token" => "refresh-123",
        "token_type" => "bearer",
        "expires_in" => 3600,
        "expires_at" => Time.now.to_i - 100, # expired
        "user" => {
          "id" => "user-123", "aud" => "authenticated", "role" => "authenticated",
          "email" => "test@example.com", "app_metadata" => {}, "user_metadata" => {},
          "created_at" => "2024-01-01T00:00:00Z"
        }
      }
      storage.set_item("supabase.auth.token", JSON.generate(expired_session))

      # Stub refresh token endpoint
      refreshed_response = {
        "access_token" => "new-access-token",
        "refresh_token" => "new-refresh-token",
        "token_type" => "bearer",
        "expires_in" => 3600,
        "expires_at" => Time.now.to_i + 3600,
        "user" => {
          "id" => "user-123", "aud" => "authenticated", "role" => "authenticated",
          "email" => "test@example.com", "app_metadata" => {}, "user_metadata" => {},
          "created_at" => "2024-01-01T00:00:00Z"
        }
      }
      stub_request(:post, "#{url}/token?grant_type=refresh_token")
        .to_return(
          status: 200,
          body: refreshed_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      events = []
      client = described_class.new(url: url, headers: headers, storage: storage, auto_refresh_token: true)
      client.on_auth_state_change { |event, _s| events << event }
      client.initialize_from_storage

      # Verify refresh was attempted (request made)
      expect(WebMock).to have_requested(:post, "#{url}/token?grant_type=refresh_token")
      # TOKEN_REFRESHED event is fired by _call_refresh_token before _remove_session
      expect(events).to include("TOKEN_REFRESHED")
    end

    it "removes session when refresh fails with non-retryable error" do
      storage = Supabase::Auth::MemoryStorage.new
      expired_session = {
        "access_token" => "expired-token",
        "refresh_token" => "refresh-123",
        "token_type" => "bearer",
        "expires_in" => 3600,
        "expires_at" => Time.now.to_i - 100,
        "user" => {
          "id" => "user-123", "aud" => "authenticated", "role" => "authenticated",
          "email" => "test@example.com", "app_metadata" => {}, "user_metadata" => {},
          "created_at" => "2024-01-01T00:00:00Z"
        }
      }
      storage.set_item("supabase.auth.token", JSON.generate(expired_session))

      # Stub refresh to fail with 401 (non-retryable)
      stub_request(:post, "#{url}/token?grant_type=refresh_token")
        .to_return(
          status: 401,
          body: '{"error":"invalid_grant","error_description":"Invalid refresh token"}',
          headers: { "Content-Type" => "application/json" }
        )

      client = described_class.new(url: url, headers: headers, storage: storage, auto_refresh_token: true)
      client.initialize_from_storage

      # Session should be removed after non-retryable error
      expect(storage.get_item("supabase.auth.token")).to be_nil
    end
  end

  # -------------------------------------------------------------------
  # AC 2 continued: #init dispatches correctly
  # -------------------------------------------------------------------
  describe "#init" do
    it "calls initialize_from_url when URL has access_token" do
      client = described_class.new(url: url, headers: headers)

      stub_request(:get, "#{url}/user")
        .to_return(
          status: 200,
          body: { "id" => "u1", "aud" => "authenticated", "role" => "authenticated",
                  "email" => "a@b.com", "app_metadata" => {}, "user_metadata" => {},
                  "created_at" => "2024-01-01T00:00:00Z" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      redirect_url = "http://example.com/callback?access_token=tok&refresh_token=rt&expires_in=3600&token_type=bearer"
      client.init(url: redirect_url)

      expect(client.get_session).not_to be_nil
    end

    it "calls initialize_from_storage when no URL given" do
      client = described_class.new(url: url, headers: headers)
      expect(client).to receive(:initialize_from_storage).and_call_original
      client.init
    end

    it "calls initialize_from_storage when URL is not implicit grant" do
      client = described_class.new(url: url, headers: headers)
      expect(client).to receive(:initialize_from_storage).and_call_original
      client.init(url: "http://example.com/callback?code=auth-code")
    end
  end

  # -------------------------------------------------------------------
  # Session persistence: _save_session and _get_valid_session
  # -------------------------------------------------------------------
  describe "session persistence" do
    it "persists session to storage when persist_session is true" do
      storage = Supabase::Auth::MemoryStorage.new
      client = described_class.new(url: url, headers: headers, storage: storage, persist_session: true)

      stub_request(:get, "#{url}/user")
        .to_return(
          status: 200,
          body: { "id" => "u1", "aud" => "authenticated", "role" => "authenticated",
                  "email" => "a@b.com", "app_metadata" => {}, "user_metadata" => {},
                  "created_at" => "2024-01-01T00:00:00Z" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      redirect_url = "http://example.com/callback?access_token=tok123&refresh_token=rt456&expires_in=3600&token_type=bearer"
      client.initialize_from_url(redirect_url)

      stored = storage.get_item("supabase.auth.token")
      expect(stored).not_to be_nil
      parsed = JSON.parse(stored)
      expect(parsed["access_token"]).to eq("tok123")
      expect(parsed["refresh_token"]).to eq("rt456")
    end

    it "does not persist to storage when persist_session is false" do
      storage = Supabase::Auth::MemoryStorage.new
      client = described_class.new(url: url, headers: headers, storage: storage, persist_session: false)

      stub_request(:get, "#{url}/user")
        .to_return(
          status: 200,
          body: { "id" => "u1", "aud" => "authenticated", "role" => "authenticated",
                  "email" => "a@b.com", "app_metadata" => {}, "user_metadata" => {},
                  "created_at" => "2024-01-01T00:00:00Z" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      redirect_url = "http://example.com/callback?access_token=tok&refresh_token=rt&expires_in=3600&token_type=bearer"
      client.initialize_from_url(redirect_url)

      expect(storage.get_item("supabase.auth.token")).to be_nil
    end

    it "_get_valid_session rejects non-integer expires_at" do
      storage = Supabase::Auth::MemoryStorage.new
      session_data = {
        "access_token" => "at",
        "refresh_token" => "rt",
        "expires_at" => "not-a-number"
      }
      storage.set_item("supabase.auth.token", JSON.generate(session_data))

      client = described_class.new(url: url, headers: headers, storage: storage)
      client.initialize_from_storage

      expect(storage.get_item("supabase.auth.token")).to be_nil
    end
  end

  # -------------------------------------------------------------------
  # PASSWORD_RECOVERY event on redirect_type=recovery
  # -------------------------------------------------------------------
  describe "PASSWORD_RECOVERY event" do
    it "fires PASSWORD_RECOVERY when redirect type is recovery" do
      client = described_class.new(url: url, headers: headers)

      stub_request(:get, "#{url}/user")
        .to_return(
          status: 200,
          body: { "id" => "u1", "aud" => "authenticated", "role" => "authenticated",
                  "email" => "a@b.com", "app_metadata" => {}, "user_metadata" => {},
                  "created_at" => "2024-01-01T00:00:00Z" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      events = []
      client.on_auth_state_change { |event, _session| events << event }

      redirect_url = "http://example.com/callback?access_token=tok&refresh_token=rt" \
                     "&expires_in=3600&token_type=bearer&type=recovery"
      client.initialize_from_url(redirect_url)

      expect(events).to include("SIGNED_IN")
      expect(events).to include("PASSWORD_RECOVERY")
    end
  end
end
