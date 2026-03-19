# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "json"

# US-014: Audit Initialization Flow
# Verifies that client initialization (from URL and from storage) matches Python behavior.
RSpec.describe "US-014: Initialization Flow Audit" do
  let(:url) { "http://localhost:9999" }
  let(:stubs) { Faraday::Adapter::Test::Stubs.new }
  let(:conn) { Faraday.new { |b| b.adapter :test, stubs } }
  let(:storage) do
    storage = Object.new
    store = {}
    storage.define_singleton_method(:get_item) { |key| store[key] }
    storage.define_singleton_method(:set_item) { |key, value| store[key] = value }
    storage.define_singleton_method(:remove_item) { |key| store.delete(key) }
    storage.define_singleton_method(:store) { store }
    storage
  end

  let(:user_data) do
    {
      "id" => "user-123",
      "aud" => "authenticated",
      "role" => "authenticated",
      "email" => "test@example.com",
      "phone" => nil,
      "app_metadata" => { "provider" => "email" },
      "user_metadata" => {},
      "identities" => [],
      "factors" => [],
      "created_at" => "2024-01-01T00:00:00Z",
      "updated_at" => "2024-01-01T00:00:00Z",
      "is_anonymous" => false
    }
  end

  let(:session_data) do
    {
      "access_token" => "test-access-token",
      "refresh_token" => "test-refresh-token",
      "token_type" => "bearer",
      "expires_in" => 3600,
      "expires_at" => Time.now.to_i + 3600,
      "user" => user_data
    }
  end

  def build_client(**opts)
    Supabase::Auth::Client.new(
      url: url,
      headers: {},
      http_client: conn,
      storage: storage,
      **opts
    )
  end

  # --- AC-3: Default options match Python ---
  describe "AC-3: Default options match Python" do
    it "auto_refresh_token defaults to true" do
      client = build_client
      expect(client.instance_variable_get(:@auto_refresh_token)).to eq(true)
    end

    it "persist_session defaults to true" do
      client = build_client
      expect(client.instance_variable_get(:@persist_session)).to eq(true)
    end

    it "detect_session_in_url defaults to true" do
      client = build_client
      expect(client.instance_variable_get(:@detect_session_in_url)).to eq(true)
    end

    it "flow_type defaults to 'implicit'" do
      client = build_client
      expect(client.instance_variable_get(:@flow_type)).to eq("implicit")
    end

    it "DEFAULT_OPTIONS hash matches Python defaults" do
      expected = {
        auto_refresh_token: true,
        persist_session: true,
        detect_session_in_url: true,
        flow_type: "implicit"
      }
      expect(Supabase::Auth::Client::DEFAULT_OPTIONS).to eq(expected)
    end

    it "DEFAULT_OPTIONS is frozen" do
      expect(Supabase::Auth::Client::DEFAULT_OPTIONS).to be_frozen
    end

    it "allows overriding auto_refresh_token" do
      client = build_client(auto_refresh_token: false)
      expect(client.instance_variable_get(:@auto_refresh_token)).to eq(false)
    end

    it "allows overriding persist_session" do
      client = build_client(persist_session: false)
      expect(client.instance_variable_get(:@persist_session)).to eq(false)
    end

    it "allows overriding flow_type to pkce" do
      client = build_client(flow_type: "pkce")
      expect(client.instance_variable_get(:@flow_type)).to eq("pkce")
    end

    it "converts flow_type to string" do
      client = build_client(flow_type: :pkce)
      expect(client.instance_variable_get(:@flow_type)).to eq("pkce")
    end
  end

  # --- AC-4: Storage key defaults to "supabase.auth.token" ---
  describe "AC-4: Storage key defaults" do
    it "storage key defaults to 'supabase.auth.token'" do
      client = build_client
      expect(client.instance_variable_get(:@storage_key)).to eq("supabase.auth.token")
    end

    it "STORAGE_KEY constant matches Python" do
      expect(Supabase::Auth::Client::STORAGE_KEY).to eq("supabase.auth.token")
    end

    it "allows custom storage key" do
      client = build_client(storage_key: "custom.key")
      expect(client.instance_variable_get(:@storage_key)).to eq("custom.key")
    end

    it "uses default MemoryStorage when no storage provided" do
      client = Supabase::Auth::Client.new(url: url, headers: {}, http_client: conn)
      storage_obj = client.instance_variable_get(:@storage)
      expect(storage_obj).to be_a(Supabase::Auth::MemoryStorage)
    end
  end

  # --- AC-5: Client correctly initializes admin and mfa sub-APIs ---
  describe "AC-5: Sub-API initialization" do
    let(:client) { build_client }

    it "initializes admin sub-API" do
      expect(client.admin).to be_a(Supabase::Auth::AdminApi)
    end

    it "initializes mfa sub-API" do
      expect(client.mfa).to be_a(Supabase::Auth::MFAApi)
    end

    it "admin API uses same URL" do
      admin_url = client.admin.instance_variable_get(:@url)
      expect(admin_url).to eq(url)
    end

    it "admin API uses same HTTP client" do
      admin_http = client.admin.instance_variable_get(:@http_client)
      expect(admin_http).to eq(conn)
    end

    it "mfa API references the parent client" do
      mfa_client = client.mfa.instance_variable_get(:@client)
      expect(mfa_client).to eq(client)
    end

    it "exposes admin via attr_reader" do
      expect(client).to respond_to(:admin)
    end

    it "exposes mfa via attr_reader" do
      expect(client).to respond_to(:mfa)
    end
  end

  # --- AC-1: initialize_from_url correctly parses implicit grant URL fragments ---
  describe "AC-1: initialize_from_url" do
    it "parses access_token, refresh_token, expires_in, token_type from URL" do
      expires_at = Time.now.to_i + 3600
      redirect_url = "http://localhost:3000/callback?access_token=at123&refresh_token=rt456&expires_in=3600&token_type=bearer"

      stubs.get("/user") do
        [200, { "Content-Type" => "application/json" }, JSON.generate(user_data)]
      end

      client = build_client
      client.initialize_from_url(redirect_url)

      session = client.instance_variable_get(:@current_session)
      expect(session).not_to be_nil
      expect(session.access_token).to eq("at123")
      expect(session.refresh_token).to eq("rt456")
      expect(session.expires_in).to eq(3600)
      expect(session.token_type).to eq("bearer")
    end

    it "parses provider_token and provider_refresh_token" do
      redirect_url = "http://localhost:3000/callback?access_token=at&refresh_token=rt&expires_in=3600&token_type=bearer&provider_token=pt123&provider_refresh_token=prt456"

      stubs.get("/user") do
        [200, { "Content-Type" => "application/json" }, JSON.generate(user_data)]
      end

      client = build_client
      client.initialize_from_url(redirect_url)

      session = client.instance_variable_get(:@current_session)
      expect(session.provider_token).to eq("pt123")
      expect(session.provider_refresh_token).to eq("prt456")
    end

    it "fetches user from /user endpoint using access_token" do
      requested_token = nil
      stubs.get("/user") do |env|
        requested_token = env.request_headers["Authorization"]
        [200, { "Content-Type" => "application/json" }, JSON.generate(user_data)]
      end

      redirect_url = "http://localhost:3000/callback?access_token=my-token&refresh_token=rt&expires_in=3600&token_type=bearer"
      client = build_client
      client.initialize_from_url(redirect_url)

      expect(requested_token).to eq("Bearer my-token")
    end

    it "saves session to storage" do
      stubs.get("/user") do
        [200, { "Content-Type" => "application/json" }, JSON.generate(user_data)]
      end

      redirect_url = "http://localhost:3000/callback?access_token=at&refresh_token=rt&expires_in=3600&token_type=bearer"
      client = build_client
      client.initialize_from_url(redirect_url)

      stored = storage.get_item("supabase.auth.token")
      expect(stored).not_to be_nil
      parsed = JSON.parse(stored)
      expect(parsed["access_token"]).to eq("at")
    end

    it "emits SIGNED_IN event" do
      stubs.get("/user") do
        [200, { "Content-Type" => "application/json" }, JSON.generate(user_data)]
      end

      events = []
      client = build_client
      client.on_auth_state_change { |event, session| events << event }

      redirect_url = "http://localhost:3000/callback?access_token=at&refresh_token=rt&expires_in=3600&token_type=bearer"
      client.initialize_from_url(redirect_url)

      expect(events).to include("SIGNED_IN")
    end

    it "emits PASSWORD_RECOVERY for recovery redirect type" do
      stubs.get("/user") do
        [200, { "Content-Type" => "application/json" }, JSON.generate(user_data)]
      end

      events = []
      client = build_client
      client.on_auth_state_change { |event, _| events << event }

      redirect_url = "http://localhost:3000/callback?access_token=at&refresh_token=rt&expires_in=3600&token_type=bearer&type=recovery"
      client.initialize_from_url(redirect_url)

      expect(events).to include("PASSWORD_RECOVERY")
    end

    it "raises AuthImplicitGrantRedirectError when error_description present" do
      client = build_client
      redirect_url = "http://localhost:3000/callback?error_description=bad+stuff&error_code=access_denied&error=unauthorized"

      expect {
        client.initialize_from_url(redirect_url)
      }.to raise_error(Supabase::Auth::Errors::AuthImplicitGrantRedirectError, "bad stuff")
    end

    it "does nothing when URL has no access_token (not implicit grant flow)" do
      # Matching Python: _is_implicit_grant_flow returns False, so initialize_from_url skips processing
      client = build_client
      redirect_url = "http://localhost:3000/callback?refresh_token=rt&expires_in=3600&token_type=bearer"

      # No error raised — URL is simply not recognized as implicit grant
      client.initialize_from_url(redirect_url)
      expect(client.instance_variable_get(:@current_session)).to be_nil
    end

    it "raises error when no refresh_token in URL" do
      client = build_client
      redirect_url = "http://localhost:3000/callback?access_token=at&expires_in=3600&token_type=bearer"

      expect {
        client.initialize_from_url(redirect_url)
      }.to raise_error(Supabase::Auth::Errors::AuthImplicitGrantRedirectError, /refresh_token/)
    end

    it "raises error when no expires_in in URL" do
      client = build_client
      redirect_url = "http://localhost:3000/callback?access_token=at&refresh_token=rt&token_type=bearer"

      expect {
        client.initialize_from_url(redirect_url)
      }.to raise_error(Supabase::Auth::Errors::AuthImplicitGrantRedirectError, /expires_in/)
    end

    it "raises error when no token_type in URL" do
      client = build_client
      redirect_url = "http://localhost:3000/callback?access_token=at&refresh_token=rt&expires_in=3600"

      expect {
        client.initialize_from_url(redirect_url)
      }.to raise_error(Supabase::Auth::Errors::AuthImplicitGrantRedirectError, /token_type/)
    end

    it "removes session on error, matching Python's except/raise pattern" do
      stubs.get("/user") { raise Faraday::ConnectionFailed, "connection failed" }

      client = build_client
      storage.set_item("supabase.auth.token", JSON.generate(session_data))

      redirect_url = "http://localhost:3000/callback?access_token=at&refresh_token=rt&expires_in=3600&token_type=bearer"

      expect {
        client.initialize_from_url(redirect_url)
      }.to raise_error(StandardError)

      expect(storage.get_item("supabase.auth.token")).to be_nil
    end

    it "does nothing when URL is not an implicit grant flow" do
      events = []
      client = build_client
      client.on_auth_state_change { |event, _| events << event }

      redirect_url = "http://localhost:3000/callback?code=auth_code_123"
      client.initialize_from_url(redirect_url)

      expect(events).to be_empty
    end
  end

  # --- _is_implicit_grant_flow ---
  describe "_is_implicit_grant_flow" do
    let(:client) { build_client }

    it "returns true when URL has access_token" do
      result = client._is_implicit_grant_flow("http://example.com?access_token=abc")
      expect(result).to be true
    end

    it "returns true when URL has error_description" do
      result = client._is_implicit_grant_flow("http://example.com?error_description=oops")
      expect(result).to be true
    end

    it "returns false when URL has neither" do
      result = client._is_implicit_grant_flow("http://example.com?code=abc")
      expect(result).to be_falsey
    end

    it "returns false for plain URL" do
      result = client._is_implicit_grant_flow("http://example.com")
      expect(result).to be_falsey
    end
  end

  # --- AC-2: initialize_from_storage recovers session and refreshes if expired ---
  describe "AC-2: initialize_from_storage" do
    it "recovers valid session from storage" do
      events = []
      client = build_client
      client.on_auth_state_change { |event, _| events << event }

      storage.set_item("supabase.auth.token", JSON.generate(session_data))
      client.initialize_from_storage

      session = client.instance_variable_get(:@current_session)
      expect(session).not_to be_nil
      expect(session.access_token).to eq("test-access-token")
      expect(events).to include("SIGNED_IN")
    end

    it "refreshes expired session when auto_refresh_token is true" do
      expired_data = session_data.merge("expires_at" => Time.now.to_i - 10)
      storage.set_item("supabase.auth.token", JSON.generate(expired_data))

      refreshed_session = {
        "access_token" => "new-access-token",
        "refresh_token" => "new-refresh-token",
        "token_type" => "bearer",
        "expires_in" => 3600,
        "expires_at" => Time.now.to_i + 3600,
        "user" => user_data
      }

      stub_request(:post, "#{url}/token?grant_type=refresh_token")
        .to_return(
          status: 200,
          body: JSON.generate(refreshed_session),
          headers: { "Content-Type" => "application/json" }
        )

      # Build client without custom http_client so WebMock intercepts
      events = []
      client = Supabase::Auth::Client.new(url: url, headers: {}, storage: storage)
      client.on_auth_state_change { |event, _| events << event }
      client.initialize_from_storage

      # Matching Python: _call_refresh_token saves session and emits TOKEN_REFRESHED,
      # then _recover_and_refresh calls _remove_session (both Python and Ruby).
      # The observable effect is the TOKEN_REFRESHED event.
      expect(events).to include("TOKEN_REFRESHED")
    end

    it "removes session when expired and auto_refresh_token is false" do
      expired_data = session_data.merge("expires_at" => Time.now.to_i - 10)
      storage.set_item("supabase.auth.token", JSON.generate(expired_data))

      client = build_client(auto_refresh_token: false)
      client.initialize_from_storage

      session = client.instance_variable_get(:@current_session)
      expect(session).to be_nil
      expect(storage.get_item("supabase.auth.token")).to be_nil
    end

    it "removes invalid session from storage" do
      storage.set_item("supabase.auth.token", "not-valid-json{{{")

      client = build_client
      client.initialize_from_storage

      expect(storage.get_item("supabase.auth.token")).to be_nil
    end

    it "removes session missing access_token" do
      bad_data = { "refresh_token" => "rt", "expires_at" => Time.now.to_i + 3600 }
      storage.set_item("supabase.auth.token", JSON.generate(bad_data))

      client = build_client
      client.initialize_from_storage

      expect(storage.get_item("supabase.auth.token")).to be_nil
    end

    it "removes session missing refresh_token" do
      bad_data = { "access_token" => "at", "expires_at" => Time.now.to_i + 3600 }
      storage.set_item("supabase.auth.token", JSON.generate(bad_data))

      client = build_client
      client.initialize_from_storage

      expect(storage.get_item("supabase.auth.token")).to be_nil
    end

    it "removes session missing expires_at" do
      bad_data = { "access_token" => "at", "refresh_token" => "rt" }
      storage.set_item("supabase.auth.token", JSON.generate(bad_data))

      client = build_client
      client.initialize_from_storage

      expect(storage.get_item("supabase.auth.token")).to be_nil
    end

    it "removes session with non-integer expires_at" do
      bad_data = { "access_token" => "at", "refresh_token" => "rt", "expires_at" => "not-a-number" }
      storage.set_item("supabase.auth.token", JSON.generate(bad_data))

      client = build_client
      client.initialize_from_storage

      expect(storage.get_item("supabase.auth.token")).to be_nil
    end

    it "does nothing when storage is empty" do
      events = []
      client = build_client
      client.on_auth_state_change { |event, _| events << event }
      client.initialize_from_storage

      expect(client.instance_variable_get(:@current_session)).to be_nil
      expect(events).to be_empty
    end

    it "uses custom storage key when configured" do
      client = build_client(storage_key: "custom.key")
      storage.set_item("custom.key", JSON.generate(session_data))

      events = []
      client.on_auth_state_change { |event, _| events << event }
      client.initialize_from_storage

      session = client.instance_variable_get(:@current_session)
      expect(session).not_to be_nil
      expect(events).to include("SIGNED_IN")
    end
  end

  # --- init method ---
  describe "init method" do
    it "calls initialize_from_url when URL has access_token" do
      stubs.get("/user") do
        [200, { "Content-Type" => "application/json" }, JSON.generate(user_data)]
      end

      client = build_client
      redirect_url = "http://localhost:3000/callback?access_token=at&refresh_token=rt&expires_in=3600&token_type=bearer"
      client.init(url: redirect_url)

      session = client.instance_variable_get(:@current_session)
      expect(session).not_to be_nil
      expect(session.access_token).to eq("at")
    end

    it "calls initialize_from_storage when no URL provided" do
      storage.set_item("supabase.auth.token", JSON.generate(session_data))

      events = []
      client = build_client
      client.on_auth_state_change { |event, _| events << event }
      client.init

      expect(events).to include("SIGNED_IN")
    end

    it "calls initialize_from_storage when URL is not implicit grant" do
      storage.set_item("supabase.auth.token", JSON.generate(session_data))

      events = []
      client = build_client
      client.on_auth_state_change { |event, _| events << event }
      client.init(url: "http://localhost:3000/callback?code=auth_code")

      expect(events).to include("SIGNED_IN")
    end
  end

  # --- _get_valid_session ---
  describe "_get_valid_session" do
    let(:client) { build_client }

    it "returns nil for nil input" do
      result = client.send(:_get_valid_session, nil)
      expect(result).to be_nil
    end

    it "returns nil for empty string" do
      result = client.send(:_get_valid_session, "")
      expect(result).to be_nil
    end

    it "returns nil for invalid JSON" do
      result = client.send(:_get_valid_session, "{invalid")
      expect(result).to be_nil
    end

    it "returns Session for valid data" do
      result = client.send(:_get_valid_session, JSON.generate(session_data))
      expect(result).to be_a(Supabase::Auth::Types::Session)
      expect(result.access_token).to eq("test-access-token")
    end

    it "parses expires_at as integer" do
      data = session_data.merge("expires_at" => "1700000000")
      result = client.send(:_get_valid_session, JSON.generate(data))
      expect(result.expires_at).to eq(1_700_000_000)
    end
  end

  # --- Constants match Python ---
  describe "Constants match Python" do
    it "EXPIRY_MARGIN is 10 seconds" do
      expect(Supabase::Auth::Client::EXPIRY_MARGIN).to eq(10)
    end

    it "STORAGE_KEY matches Python" do
      expect(Supabase::Auth::Client::STORAGE_KEY).to eq("supabase.auth.token")
    end

    it "JWKS_TTL is 600 seconds (10 minutes)" do
      expect(Supabase::Auth::Client::JWKS_TTL).to eq(600)
    end

    it "MAX_RETRIES is 10" do
      expect(Supabase::Auth::Constants::MAX_RETRIES).to eq(10)
    end

    it "RETRY_INTERVAL is 2" do
      expect(Supabase::Auth::Constants::RETRY_INTERVAL).to eq(2)
    end
  end

  # --- Client state initialization ---
  describe "Client state initialization" do
    let(:client) { build_client }

    it "current_session starts as nil" do
      expect(client.instance_variable_get(:@current_session)).to be_nil
    end

    it "jwks starts as empty keys hash" do
      expect(client.instance_variable_get(:@jwks)).to eq({ "keys" => [] })
    end

    it "jwks_cached_at starts as nil" do
      expect(client.instance_variable_get(:@jwks_cached_at)).to be_nil
    end

    it "state_change_emitters starts as empty hash" do
      expect(client.instance_variable_get(:@state_change_emitters)).to eq({})
    end

    it "refresh_token_timer starts as nil" do
      expect(client.instance_variable_get(:@refresh_token_timer)).to be_nil
    end

    it "network_retries starts at 0" do
      expect(client.instance_variable_get(:@network_retries)).to eq(0)
    end
  end
end
